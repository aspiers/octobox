# frozen_string_literal: true

require "digest"
require "uri"

class SubjectReferenceSync
  PER_PAGE = 100
  MAX_PAGES = 10
  MAX_ACTIVITIES = 200
  TIMELINE_ACCEPT = "application/vnd.github.mockingbird-preview+json, application/vnd.github+json"
  API_ACCEPT = "application/vnd.github+json"
  API_VERSION = "2022-11-28"
  UNIQUE_INDEX = :index_reference_activities_on_subject_and_identity
  MUTABLE_COLUMNS = %i[
    github_id github_node_id activity_type source_type source_repository_full_name
    source_number source_identifier source_title source_author body_snippet native_url occurred_at
  ].freeze
  PERSISTED_COLUMNS = ([:stable_identity] + MUTABLE_COLUMNS).freeze
  API_ERRORS = [Octokit::Error, Faraday::Error].freeze

  class IncompleteSnapshot < StandardError; end

  def self.call(subject, client)
    new(subject, client).call
  end

  def initialize(subject, client)
    @subject = subject
    @client = client
    @source_repository_visibility = {}
  end

  def call
    return purge_private_activity if private_target?
    return false unless client && public_target? && issue_or_pull_request?

    snapshot_started_at = Time.current
    identity = subject_identity
    timeline = fetch_timeline
    relevant_events = timeline.select { |event| relevant_event?(event) }
    if relevant_events.length > MAX_ACTIVITIES
      raise IncompleteSnapshot, "timeline has more than #{MAX_ACTIVITIES} reference events"
    end

    attributes = relevant_events.filter_map { |event| activity_attributes(event) }
    persist_snapshot(attributes, identity, snapshot_started_at)
  rescue *API_ERRORS, IncompleteSnapshot => error
    Rails.logger.warn("Reference activity sync failed for #{subject.url}: #{error.class}: #{error.message}")
    false
  end

  private

  attr_reader :subject, :client, :source_repository_visibility

  def fetch_timeline
    records = []

    1.upto(MAX_PAGES) do |page|
      batch = Array(client.get(
        timeline_url,
        per_page: PER_PAGE,
        page: page,
        accept: TIMELINE_ACCEPT,
        headers: { "X-GitHub-Api-Version" => API_VERSION }
      ))
      records.concat(batch)
      return records if batch.length < PER_PAGE
    end

    raise IncompleteSnapshot, "timeline pagination exceeded #{MAX_PAGES} pages"
  end

  def activity_attributes(remote_event)
    event = resource_hash(remote_event)

    case event["event"]
    when "cross-referenced"
      issue_reference_attributes(event, "cross_reference")
    when "mentioned"
      issue_reference_attributes(event, "mention")
    when "referenced"
      commit_reference_attributes(event)
    end
  end

  def issue_reference_attributes(event, activity_type)
    source_issue = resource_hash(event.dig("source", "issue"))
    return if source_issue.empty?

    repository_full_name = source_repository_name(source_issue)
    return unless repository_full_name && public_source_repository?(repository_full_name, source_issue["repository"])

    native_url = safe_github_url(source_issue["html_url"])
    occurred_at = event["created_at"] || source_issue["created_at"]
    return unless native_url && occurred_at

    source_type = source_issue["pull_request"].present? ? "pull_request" : "issue"
    common_attributes(event, activity_type, source_type, repository_full_name, native_url, occurred_at).merge(
      source_number: source_issue["number"],
      source_identifier: source_issue["node_id"] || source_issue["id"]&.to_s,
      source_title: clean_text(source_issue["title"], 500),
      source_author: clean_text(source_issue.dig("user", "login") || event.dig("actor", "login"), 255),
      body_snippet: text_snippet(source_issue["body"])
    )
  end

  def commit_reference_attributes(event)
    commit_id = event["commit_id"].presence
    commit_url = event["commit_url"].presence
    repository_full_name = repository_name_from_api_url(commit_url)
    return unless commit_id && repository_full_name
    return unless public_source_repository?(repository_full_name)

    commit = resource_hash(client.get(
      commit_url,
      accept: API_ACCEPT,
      headers: { "X-GitHub-Api-Version" => API_VERSION }
    ))
    message = commit.dig("commit", "message").to_s
    native_url = safe_github_url(commit["html_url"] || native_commit_url(repository_full_name, commit_id))
    occurred_at = event["created_at"] || commit.dig("commit", "author", "date")
    return unless native_url && occurred_at

    common_attributes(event, "commit_reference", "commit", repository_full_name, native_url, occurred_at).merge(
      source_identifier: commit_id,
      source_title: clean_text(message.lines.first, 500).presence || commit_id.first(12),
      source_author: clean_text(commit.dig("author", "login") || event.dig("actor", "login") || commit.dig("commit", "author", "name"), 255),
      body_snippet: text_snippet(message)
    )
  end

  def common_attributes(event, activity_type, source_type, repository_full_name, native_url, occurred_at)
    {
      stable_identity: stable_identity(event, activity_type, native_url, occurred_at),
      github_id: event["id"],
      github_node_id: event["node_id"],
      activity_type: activity_type,
      source_type: source_type,
      source_repository_full_name: repository_full_name,
      native_url: native_url,
      occurred_at: occurred_at
    }
  end

  def stable_identity(event, activity_type, native_url, occurred_at)
    return "node:#{event["node_id"]}" if event["node_id"].present?
    return "#{activity_type}:#{event["id"]}" if event["id"].present?

    material = [activity_type, native_url, occurred_at.to_s].join("\0")
    "generated:#{Digest::SHA256.hexdigest(material)}"
  end

  def persist_snapshot(attributes, identity, snapshot_started_at)
    now = Time.current
    rows = attributes.index_by { |attrs| attrs.fetch(:stable_identity) }.values.map do |attrs|
      normalized = PERSISTED_COLUMNS.index_with { |column| attrs[column] }
      normalized.merge(subject_id: subject.id, created_at: now, updated_at: now)
    end

    subject.with_lock do
      return false unless subject_identity == identity
      return false if subject.reference_activities_sync_started_at &&
        subject.reference_activities_sync_started_at >= snapshot_started_at

      if rows.present?
        ReferenceActivity.upsert_all(rows, unique_by: UNIQUE_INDEX, update_only: MUTABLE_COLUMNS)
      end

      identities = rows.pluck(:stable_identity)
      stale_scope = subject.reference_activities
      stale_scope = stale_scope.where.not(stable_identity: identities) if identities.present?
      stale_scope.delete_all
      subject.update_column(:reference_activities_sync_started_at, snapshot_started_at)
    end

    true
  end

  def purge_private_activity
    return false unless private_target?

    subject.with_lock do
      subject.reference_activities.delete_all
      subject.update_column(:reference_activities_sync_started_at, Time.current)
    end
    false
  end

  def public_source_repository?(repository_full_name, remote_repository = nil)
    cached = source_repository_visibility[repository_full_name]
    return cached unless cached.nil?

    if repository_full_name.casecmp?(subject.repository_full_name.to_s)
      return source_repository_visibility[repository_full_name] = public_target?
    end

    repository = resource_hash(remote_repository)
    if repository.key?("private")
      return source_repository_visibility[repository_full_name] = !repository["private"]
    end

    repository = resource_hash(client.get(
      "repos/#{repository_full_name}",
      accept: API_ACCEPT,
      headers: { "X-GitHub-Api-Version" => API_VERSION }
    ))
    unless repository.key?("private")
      raise IncompleteSnapshot, "repository visibility missing for #{repository_full_name}"
    end

    source_repository_visibility[repository_full_name] = !repository["private"]
  end

  def public_target?
    subject.repository.present? && !subject.repository.private?
  end

  def private_target?
    subject.repository&.private? == true
  end

  def issue_or_pull_request?
    subject.url.to_s.match?(%r{/issues/\d+\z|/pulls/\d+\z})
  end

  def timeline_url
    "#{subject.url.to_s.gsub("/pulls/", "/issues/")}/timeline"
  end

  def subject_identity
    updated_at_microseconds = (subject.updated_at.to_r * 1_000_000).floor if subject.updated_at
    [subject.url, subject.repository_full_name, subject.github_id, updated_at_microseconds]
  end

  def relevant_event?(event)
    %w[cross-referenced mentioned referenced].include?(value(event, "event").to_s)
  end

  def source_repository_name(source_issue)
    source_issue.dig("repository", "full_name").presence ||
      repository_name_from_api_url(source_issue["repository_url"]) ||
      repository_name_from_api_url(source_issue["url"])
  end

  def repository_name_from_api_url(url)
    match = url.to_s.match(%r{/repos/([^/]+/[^/]+)(?:/|\z)})
    match && match[1]
  end

  def native_commit_url(repository_full_name, commit_id)
    "#{Octobox.config.github_domain}/#{repository_full_name}/commit/#{commit_id}"
  end

  def safe_github_url(value)
    uri = URI.parse(value.to_s)
    github_uri = URI.parse(Octobox.config.github_domain)
    return unless %w[http https].include?(uri.scheme)
    return unless uri.host == github_uri.host && uri.userinfo.nil?

    uri.to_s
  rescue URI::InvalidURIError
    nil
  end

  def clean_text(value, limit)
    value.to_s.delete("\u0000").strip.truncate(limit, omission: "…")
  end

  def text_snippet(value)
    clean_text(value.to_s.squish, 500).presence
  end

  def resource_hash(resource)
    return {} if resource.nil?

    resource.to_h.deep_stringify_keys
  end

  def value(object, key)
    return if object.nil?
    return object[key] if object.respond_to?(:key?) && object.key?(key)
    return object[key.to_sym] if object.respond_to?(:key?) && object.key?(key.to_sym)

    object[key]
  rescue NoMethodError, TypeError
    nil
  end
end
