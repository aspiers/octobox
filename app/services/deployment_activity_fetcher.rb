# frozen_string_literal: true

require 'digest'
require 'erb'
require 'uri'

class DeploymentActivityFetcher
  Result = Struct.new(:events, :total_count, :complete, keyword_init: true)
  AuthorizationError = Class.new(StandardError)
  InvalidSubjectError = Class.new(StandardError)

  TIMELINE_EVENTS = %w[deployed deployment_environment_changed].freeze
  PAGE_SIZE = 100
  MAX_TIMELINE_PAGES = 5
  MAX_DEPLOYMENTS = 50
  MAX_STATUS_PAGES = 1

  def initialize(subject:, client:)
    @subject = subject
    @client = client
  end

  def call
    validate_subject!
    timeline, complete = fetch_timeline
    deployment_events = timeline.filter_map do |event|
      event = event.to_h.deep_stringify_keys
      event if TIMELINE_EVENTS.include?(event['event'])
    end

    deployments, deployments_complete = fetch_deployments(deployment_events)
    complete &&= deployments_complete
    statuses, statuses_complete = fetch_statuses(deployments)
    complete &&= statuses_complete

    events = deployment_events.map { |event| normalize_event(event, deployments, statuses) }
    events.sort_by! { |event| event['occurred_at'].to_s }
    events.reverse!

    Result.new(events: events.first(DeploymentActivitySnapshot::DISPLAY_LIMIT),
               total_count: events.length,
               complete: complete)
  end

  private

  attr_reader :subject, :client

  def validate_subject!
    raise InvalidSubjectError, 'Deployment activity is only available for pull requests' unless subject.pull_request?
    raise InvalidSubjectError, 'Invalid GitHub repository name' unless repository_parts
    raise InvalidSubjectError, 'Pull request number is missing' unless subject_number
  end

  def repository_parts
    @repository_parts ||= subject.repository_full_name&.match(/\A([\w.-]+)\/([\w.-]+)\z/)&.captures
  end

  def subject_number
    @subject_number ||= subject.url.to_s[/\d+\z/]
  end

  def api_prefix
    Octobox.config.github_api_prefix.delete_suffix('/')
  end

  def web_prefix
    Octobox.config.github_domain.delete_suffix('/')
  end

  def repository_api_url
    "#{api_prefix}/repos/#{repository_parts.join('/')}"
  end

  def timeline_url
    "#{repository_api_url}/issues/#{subject_number}/timeline"
  end

  def fetch_timeline
    first_page = Array(client.get(timeline_url, per_page: PAGE_SIZE, page: 1))
    return [first_page, true] if first_page.length < PAGE_SIZE

    last_page = last_page_number
    return fetch_pages(timeline_url, max_pages: MAX_TIMELINE_PAGES) unless last_page

    pages = if last_page <= MAX_TIMELINE_PAGES
              (2..last_page).to_a
            else
              ((last_page - MAX_TIMELINE_PAGES + 1)..last_page).to_a
            end
    records = last_page <= MAX_TIMELINE_PAGES ? first_page : []
    pages.each { |page| records.concat(Array(client.get(timeline_url, per_page: PAGE_SIZE, page: page))) }
    [records, last_page <= MAX_TIMELINE_PAGES]
  end

  def last_page_number
    href = client.last_response&.rels&.[](:last)&.href
    URI.parse(href.to_s).query.to_s.split('&').filter_map do |parameter|
      key, value = parameter.split('=', 2)
      value.to_i if key == 'page'
    end.first
  rescue URI::InvalidURIError
    nil
  end

  def fetch_pages(url, max_pages:, options: {})
    records = []

    1.upto(max_pages) do |page|
      response = client.get(url, options.merge(per_page: PAGE_SIZE, page: page))
      page_records = Array(response)
      records.concat(page_records)
      return [records, true] if page_records.length < PAGE_SIZE
    end

    [records, false]
  end

  def fetch_deployments(events)
    nested = events.filter_map { |event| event['deployment'] }.map { |deployment| deployment.to_h.deep_stringify_keys }
    missing_details = events.any? { |event| event['deployment'].blank? || event['deployment_status'].blank? }
    return [index_deployments(nested), true] unless missing_details

    shas = events.filter_map { |event| event['commit_id'].presence }
    shas << subject.sha if subject.sha.present?
    fetched = []
    complete = true

    shas.uniq.each do |sha|
      remaining = MAX_DEPLOYMENTS - fetched.length
      break if remaining <= 0

      response = Array(client.get("#{repository_api_url}/deployments", sha: sha, per_page: remaining, page: 1))
      fetched.concat(response.first(remaining).map { |deployment| deployment.to_h.deep_stringify_keys })
      complete &&= response.length < remaining
    end

    [index_deployments(nested + fetched), complete]
  rescue Octokit::Forbidden, Octokit::Unauthorized, Octokit::NotFound
    [index_deployments(nested), false]
  end

  def index_deployments(deployments)
    deployments.each_with_object({}) do |deployment, indexed|
      id = deployment['id'] || deployment['node_id']
      indexed[id.to_s] = deployment if id
    end
  end

  def fetch_statuses(deployments)
    statuses = Hash.new { |hash, key| hash[key] = [] }
    complete = true

    deployments.keys.first(MAX_DEPLOYMENTS).each do |id|
      status_url = "#{repository_api_url}/deployments/#{id}/statuses"
      records, page_complete = fetch_pages(status_url, max_pages: MAX_STATUS_PAGES)
      statuses[id].concat(records.map { |status| status.to_h.deep_stringify_keys })
      complete &&= page_complete
    rescue Octokit::NotFound
      # GHES versions predating deployment statuses can still return timeline events.
    rescue Octokit::Forbidden, Octokit::Unauthorized
      complete = false
    end

    [statuses, complete]
  end

  def normalize_event(event, deployments, statuses)
    deployment = event['deployment']&.to_h&.deep_stringify_keys
    status = event['deployment_status']&.to_h&.deep_stringify_keys
    deployment_id = deployment_identifier(deployment, status)
    deployment ||= deployments[deployment_id]
    deployment ||= closest_deployment(event, deployments.values)
    deployment_id ||= deployment_identifier(deployment, status)
    status ||= matching_status(event, statuses[deployment_id], event['event'])

    environment = clean_text(status&.dig('environment') || deployment&.dig('environment') || deployment&.dig('original_environment'))
    actor = event['actor']&.to_h&.deep_stringify_keys || status&.dig('creator') || {}

    {
      'id' => stable_event_id(event),
      'kind' => event['event'],
      'environment' => environment,
      'outcome' => clean_text(status&.dig('state'))&.downcase,
      'occurred_at' => normalized_time(event['created_at'] || status&.dig('created_at')),
      'actor_login' => clean_text(actor['login']),
      'actor_url' => trusted_url(actor['html_url'] || actor['url']),
      'url' => native_deployment_url(environment, status),
      'deployment_id' => clean_text(deployment&.dig('id') || deployment_id)
    }.compact
  end

  def deployment_identifier(deployment, status)
    id = deployment&.dig('id') || deployment&.dig('node_id')
    id ||= status&.dig('deployment_url').to_s[%r{/deployments/([^/]+)\z}, 1]
    id&.to_s
  end

  def closest_deployment(event, deployments)
    candidates = deployments.select do |deployment|
      event['commit_id'].blank? || [deployment['sha'], deployment['ref']].include?(event['commit_id'])
    end
    closest_by_time(candidates, event['created_at'])
  end

  def matching_status(event, deployment_statuses, kind)
    candidates = Array(deployment_statuses)
    return candidates.max_by { |status| parse_time(status['created_at']) || Time.at(0) } if kind == 'deployed'

    closest_by_time(candidates, event['created_at'])
  end

  def closest_by_time(records, target)
    target_time = parse_time(target)
    return records.first unless target_time

    records.min_by do |record|
      record_time = parse_time(record['created_at'] || record['updated_at'])
      record_time ? (record_time - target_time).abs : Float::INFINITY
    end
  end

  def stable_event_id(event)
    remote_id = event['node_id'] || event['id']
    return "timeline:#{remote_id}" if remote_id.present?

    digest = Digest::SHA256.hexdigest([event['event'], event['commit_id'], event['created_at']].join(':'))
    "timeline:#{digest}"
  end

  def normalized_time(value)
    parse_time(value)&.utc&.iso8601
  end

  def parse_time(value)
    Time.zone.parse(value.to_s) if value.present?
  rescue ArgumentError
    nil
  end

  def clean_text(value)
    value.to_s.encode('UTF-8', invalid: :replace, undef: :replace).delete("\u0000").slice(0, 255).presence
  end

  def native_deployment_url(environment, status)
    candidate = status && [status['environment_url'], status['log_url'], status['target_url']].find { |url| trusted_url(url) }
    return trusted_url(candidate) if candidate
    return unless environment

    trusted_url("#{web_prefix}/#{repository_parts.join('/')}/deployments/#{ERB::Util.url_encode(environment)}")
  end

  def trusted_url(value)
    return if value.blank?

    candidate = URI.parse(value.to_s)
    return unless %w[http https].include?(candidate.scheme) && candidate.host && !candidate.userinfo

    allowed = [Octobox.config.github_domain, Octobox.config.github_api_prefix].any? do |configured|
      origin(candidate) == origin(URI.parse(configured))
    end
    value.to_s if allowed
  rescue URI::InvalidURIError
    nil
  end

  def origin(uri)
    [uri.scheme&.downcase, uri.host&.downcase, uri.port]
  end
end
