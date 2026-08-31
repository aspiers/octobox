# frozen_string_literal: true

require "uri"

class SubjectCiSync
  PER_PAGE = 100
  MAX_PAGES = 20
  class IncompleteSnapshot < StandardError; end

  UNIQUE_INDEX = :index_ci_activities_on_subject_kind_github_id
  MUTABLE_COLUMNS = %i[
    head_sha name state conclusion description summary app_name check_suite_id
    target_url github_created_at github_updated_at started_at completed_at
  ].freeze
  API_ERRORS = [Octokit::ClientError, Octokit::ServerError, Faraday::Error, IncompleteSnapshot].freeze

  def self.call(subject, client)
    return unless client && subject.sha.present?

    new(subject, client).call
  end

  def initialize(subject, client)
    @subject = subject
    @client = client
    @head_sha = subject.sha
    @repository_full_name = subject.repository_full_name
  end

  def call
    sync_aggregate_status
    sync_source("status") { fetch_statuses.map { |status| status_attributes(status) } }
    sync_source("check_run") { fetch_check_runs.map { |check_run| check_run_attributes(check_run) } }
    sync_source("check_suite") { fetch_check_suites.map { |suite| check_suite_attributes(suite) } }
  end

  private

  attr_reader :subject, :client, :head_sha, :repository_full_name

  def sync_aggregate_status
    remote_status = resource_hash(client.combined_status(repository_full_name, head_sha))
    status = remote_status["state"]
    status = nil if status == "pending" && Array(remote_status["statuses"]).empty?
    subject.with_lock do
      subject.update!(status: status) if subject.sha == head_sha && subject.status != status
    end
  rescue *API_ERRORS => error
    log_api_failure("combined_status", error)
  end

  def sync_source(kind)
    snapshot = yield
    now = Time.current
    rows = snapshot.index_by { |attributes| attributes.fetch(:github_id) }.values.map do |attributes|
      attributes.merge(subject_id: subject.id, kind: kind, created_at: now, updated_at: now)
    end

    subject.with_lock do
      return unless subject.sha == head_sha && subject.repository_full_name == repository_full_name

      existing = subject.ci_activities.where(kind: kind, github_id: rows.pluck(:github_id)).index_by(&:github_id)
      current_rows = rows.reject do |row|
        stored_at = existing[row.fetch(:github_id)]&.github_updated_at
        remote_at = row[:github_updated_at]
        stored_at && remote_at && stored_at > remote_at
      end
      if current_rows.present?
        CiActivity.upsert_all(current_rows, unique_by: UNIQUE_INDEX, update_only: MUTABLE_COLUMNS)
      end

      subject.ci_activities.where(kind: kind).where.not(head_sha: head_sha).delete_all
    end
  rescue *API_ERRORS => error
    log_api_failure(kind, error)
  end

  def fetch_statuses
    fetch_array_pages do |page|
      client.get(
        "#{Octokit::Repository.path(repository_full_name)}/statuses/#{head_sha}",
        per_page: PER_PAGE,
        page: page
      )
    end
  end

  def fetch_check_runs
    records = []
    page = 1

    loop do
      response = resource_hash(client.get(
        "#{Octokit::Repository.path(repository_full_name)}/commits/#{head_sha}/check-runs",
        per_page: PER_PAGE,
        page: page,
        filter: "all"
      ))
      batch = Array(response["check_runs"])
      records.concat(batch)
      total_count = response["total_count"]
      if batch.length < PER_PAGE
        if total_count && records.length < total_count.to_i
          raise IncompleteSnapshot, "check-run snapshot ended before total_count"
        end
        break
      end
      break if total_count && records.length >= total_count.to_i
      raise IncompleteSnapshot, "check-run pagination exceeded #{MAX_PAGES} pages" if page >= MAX_PAGES

      page += 1
    end

    records
  end

  def fetch_check_suites
    fetch_object_pages("check_suites") do |page|
      client.get(
        "#{Octokit::Repository.path(repository_full_name)}/commits/#{head_sha}/check-suites",
        per_page: PER_PAGE,
        page: page
      )
    end
  end

  def fetch_object_pages(collection_key)
    records = []
    page = 1

    loop do
      response = resource_hash(yield(page))
      batch = Array(response[collection_key])
      records.concat(batch)
      total_count = response["total_count"]
      if batch.length < PER_PAGE
        raise IncompleteSnapshot, "#{collection_key} snapshot ended before total_count" if total_count && records.length < total_count.to_i
        break
      end
      break if total_count && records.length >= total_count.to_i
      raise IncompleteSnapshot, "#{collection_key} pagination exceeded #{MAX_PAGES} pages" if page >= MAX_PAGES

      page += 1
    end

    records
  end

  def fetch_array_pages
    records = []
    page = 1

    loop do
      batch = Array(yield(page))
      records.concat(batch)
      break if batch.length < PER_PAGE
      raise IncompleteSnapshot, "status pagination exceeded #{MAX_PAGES} pages" if page >= MAX_PAGES

      page += 1
    end

    records
  end

  def status_attributes(remote_status)
    status = resource_hash(remote_status)
    {
      github_id: status.fetch("id"),
      head_sha: head_sha,
      name: clean_text(status["context"]).presence || "default",
      state: status["state"],
      conclusion: nil,
      description: clean_text(status["description"]),
      summary: nil,
      app_name: nil,
      check_suite_id: nil,
      target_url: safe_url(status["target_url"]),
      github_created_at: status["created_at"],
      github_updated_at: status["updated_at"],
      started_at: nil,
      completed_at: nil
    }
  end

  def check_run_attributes(remote_check_run)
    check_run = resource_hash(remote_check_run)
    output = resource_hash(check_run["output"])
    app = resource_hash(check_run["app"])
    check_suite = resource_hash(check_run["check_suite"])

    {
      github_id: check_run.fetch("id"),
      head_sha: check_run["head_sha"].presence || head_sha,
      name: clean_text(check_run["name"]).presence || "Check run",
      state: check_run["status"],
      conclusion: check_run["conclusion"],
      description: clean_text(output["title"]),
      summary: clean_text(output["summary"]),
      app_name: clean_text(app["name"] || app["slug"]),
      check_suite_id: check_suite["id"],
      target_url: safe_url(check_run["details_url"] || check_run["html_url"]),
      github_created_at: check_run["created_at"],
      github_updated_at: check_run["updated_at"],
      started_at: check_run["started_at"],
      completed_at: check_run["completed_at"]
    }
  end

  def check_suite_attributes(remote_suite)
    suite = resource_hash(remote_suite)
    app = resource_hash(suite["app"])
    app_name = clean_text(app["name"] || app["slug"])
    {
      github_id: suite.fetch("id"),
      head_sha: suite["head_sha"].presence || head_sha,
      name: app_name.present? ? "#{app_name} check suite" : "Check suite",
      state: suite["status"],
      conclusion: suite["conclusion"],
      description: nil,
      summary: nil,
      app_name: app_name,
      check_suite_id: suite["id"],
      target_url: safe_url("https://github.com/#{repository_full_name}/commit/#{head_sha}/checks?check_suite_id=#{suite.fetch("id")}"),
      github_created_at: suite["created_at"],
      github_updated_at: suite["updated_at"],
      started_at: nil,
      completed_at: suite["latest_check_runs_count"].to_i.positive? ? suite["updated_at"] : nil
    }
  end

  def resource_hash(resource)
    return {} if resource.nil?

    resource.to_h.deep_stringify_keys
  end

  def clean_text(value)
    value.to_s.delete("\u0000").presence
  end

  def safe_url(value)
    uri = URI.parse(value.to_s)
    return unless uri.is_a?(URI::HTTP) && uri.host.present? && uri.userinfo.nil?

    uri.to_s
  rescue URI::InvalidURIError
    nil
  end

  def log_api_failure(source, error)
    GithubPreviewFetcher.log_failure(error, operation: source, subject_url: subject.url)
  end
end
