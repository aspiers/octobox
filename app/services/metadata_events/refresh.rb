# frozen_string_literal: true

require 'digest'
require 'uri'

module MetadataEvents
  class Refresh
    PAGE_SIZE = 100
    MAX_PAGES = 100

    IncompleteSnapshot = Class.new(StandardError)
    Result = Data.define(:snapshot, :outcome)

    def initialize(subject:, viewer: nil, client: nil)
      @subject = subject
      @viewer = viewer
      @client = client
    end

    def call(force: true)
      return Result.new(snapshot: nil, outcome: :unsupported) unless subject.issue_or_pull_request?
      return withhold_private_data unless authorized_scope?

      subject.metadata_event_snapshots.publicly_visible.destroy_all if private_repository?
      existing_snapshot = MetadataEventSnapshot.find_by(subject: subject, scope_key: scope_key)
      return Result.new(snapshot: existing_snapshot, outcome: :fresh) if !force && existing_snapshot&.fresh?

      snapshot, generation = begin_refresh
      events, complete = download_events
      return finish_incomplete(snapshot, generation) unless complete

      finish_complete(snapshot, generation, events)
    rescue IncompleteSnapshot => error
      finish_incomplete(snapshot, generation, error)
    rescue Octokit::TooManyRequests => error
      finish_failed(snapshot, generation, error)
    rescue Octokit::NotFound, Octokit::Unauthorized, Octokit::Forbidden
      revoke_snapshot(snapshot, generation)
    rescue Octokit::ClientError, Faraday::Error, Timeout::Error => error
      finish_failed(snapshot, generation, error)
    end

    private

    attr_reader :subject, :viewer

    def authorized_scope?
      return true unless private_repository?

      viewer.present? && subject.notifications.exists?(user_id: viewer.id) && authorized_private_client.present?
    end

    def private_repository?
      subject.repository&.private?
    end

    def scope_key
      private_repository? ? "viewer:#{viewer.id}" : 'public'
    end

    def begin_refresh
      snapshot = find_or_create_snapshot
      generation = nil
      snapshot.with_lock do
        generation = snapshot.generation + 1
        snapshot.update!(generation: generation, status: 'refreshing',
                         refresh_started_at: Time.current, failed_at: nil)
      end
      [snapshot, generation]
    end

    def find_or_create_snapshot
      MetadataEventSnapshot.find_or_create_by!(subject: subject, scope_key: scope_key) do |record|
        record.viewer = viewer if private_repository?
      end
    rescue ActiveRecord::RecordNotUnique
      retry
    end

    def download_events
      events = []
      complete = false
      (1..MAX_PAGES).each do |page|
        page_events = Array(api_client.get(timeline_url, per_page: PAGE_SIZE, page: page))
        events.concat(page_events.map { |event| event.respond_to?(:to_h) ? event.to_h : event })
        if page_events.length < PAGE_SIZE
          complete = true
          break
        end
      end
      [events.filter_map { |event| attributes_for(event) }, complete]
    end

    def api_client
      @client ||= if private_repository?
        authorized_private_client
      else
        subject.app_installation&.github_client || viewer&.github_client ||
          Octokit::Client.new(auto_paginate: false)
      end
    end

    def authorized_private_client
      return @authorized_private_client if defined?(@authorized_private_client)

      installation = subject.app_installation
      @authorized_private_client = if installation && viewer.app_installations.exists?(id: installation.id)
        installation.github_client
      elsif viewer.effective_access_token.present?
        Octokit::Client.new(access_token: viewer.effective_access_token, auto_paginate: false)
      end
    end

    def timeline_url
      subject_uri = URI.parse(subject.url.to_s)
      api_uri = URI.parse(Octobox.config.github_api_prefix)
      base_path = api_uri.path.to_s.sub(%r{/\z}, '')
      valid_origin = subject_uri.scheme == api_uri.scheme &&
        subject_uri.host == api_uri.host && subject_uri.port == api_uri.port &&
        subject_uri.userinfo.nil?
      valid_path = subject_uri.path.match?(%r{\A#{Regexp.escape(base_path)}/repos/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+/(?:issues|pulls)/\d+\z})
      valid_url = subject_uri.query.nil? && subject_uri.fragment.nil?
      raise IncompleteSnapshot, 'invalid subject timeline URL' unless valid_origin && valid_path && valid_url

      "#{subject_uri.to_s.sub('/pulls/', '/issues/')}/timeline"
    rescue URI::InvalidURIError
      raise IncompleteSnapshot, 'invalid subject timeline URL'
    end

    def attributes_for(remote_event)
      event = remote_event.to_h.deep_stringify_keys
      event_type = canonical_event_type(event['event'])
      return unless event_type
      return unless event['created_at']

      attributes = {
        event_type: event_type,
        actor_login: event.dig('actor', 'login'),
        occurred_at: event['created_at'],
        before_metadata: before_metadata(event_type, event),
        after_metadata: after_metadata(event_type, event),
        source_context: source_context(event),
        native_url: native_url(event),
        github_event_id: integer_id(event['id'])
      }
      attributes[:github_identity] = identity_for(event, attributes)
      attributes
    end

    def canonical_event_type(value)
      value = value.to_s.tr('-', '_')
      MetadataEvent::EVENT_TYPES.find { |type| type == value }
    end

    def before_metadata(type, event)
      case type
      when 'renamed' then compact_hash('title' => event.dig('rename', 'from'))
      when 'unlabeled' then compact_hash('label' => label_context(event['label']))
      when 'unassigned' then compact_hash('assignee' => actor_context(event['assignee']))
      when 'demilestoned' then compact_hash('milestone' => milestone_context(event['milestone']))
      when 'unlocked' then compact_hash('locked' => true, 'reason' => event['lock_reason'])
      when 'transferred' then compact_hash('repository' => repository_context(event['from_repository']))
      when 'disconnected' then compact_hash('source' => source_context(event))
      else {}
      end
    end

    def after_metadata(type, event)
      case type
      when 'renamed' then compact_hash('title' => event.dig('rename', 'to'))
      when 'labeled' then compact_hash('label' => label_context(event['label']))
      when 'assigned' then compact_hash('assignee' => actor_context(event['assignee']))
      when 'milestoned' then compact_hash('milestone' => milestone_context(event['milestone']))
      when 'locked' then compact_hash('locked' => true, 'reason' => event['lock_reason'])
      when 'unlocked' then { 'locked' => false }
      when 'transferred' then compact_hash('repository' => repository_context_for_subject)
      when 'connected' then compact_hash('source' => source_context(event))
      else {}
      end
    end

    def label_context(label)
      return unless label
      compact_hash('name' => label['name'], 'color' => label['color'])
    end

    def actor_context(actor)
      return unless actor
      compact_hash('login' => actor['login'])
    end

    def milestone_context(milestone)
      return unless milestone
      compact_hash('title' => milestone['title'], 'number' => milestone['number'])
    end

    def repository_context(repository)
      return unless repository
      compact_hash('full_name' => repository['full_name'], 'html_url' => safe_github_url(repository['html_url']))
    end

    def repository_context_for_subject
      compact_hash('full_name' => subject.repository_full_name,
                   'html_url' => safe_github_url(subject.repository && "#{Octobox.config.github_domain}/#{subject.repository.full_name}"))
    end

    def source_context(event)
      source = event['source']
      return {} unless source.is_a?(Hash)

      issue = source['issue'] || source['pull_request'] || source
      repository = source['repository'] || issue['repository'] || {}
      compact_hash(
        'type' => source['type'] || (issue['pull_request'] ? 'pull_request' : 'issue'),
        'repository_full_name' => repository['full_name'] || repository_name_from_url(issue['repository_url']),
        'number' => issue['number'],
        'title' => issue['title'],
        'state' => issue['state'],
        'url' => safe_github_url(issue['html_url'])
      )
    end

    def native_url(event)
      safe_github_url(event['html_url']) || begin
        return unless subject.html_url && event['id']
        safe_github_url("#{subject.html_url}#event-#{event['id']}")
      end
    end

    def safe_github_url(value)
      return if value.blank?
      uri = URI.parse(value.to_s)
      github_uri = URI.parse(Octobox.config.github_domain)
      return unless %w[http https].include?(uri.scheme)
      return unless uri.scheme == github_uri.scheme && uri.host == github_uri.host &&
                    uri.port == github_uri.port && uri.userinfo.nil?

      uri.to_s
    rescue URI::InvalidURIError
      nil
    end

    def repository_name_from_url(url)
      URI.parse(url.to_s).path[%r{/repos/([^/]+/[^/]+)\z}, 1]
    rescue URI::InvalidURIError
      nil
    end

    def compact_hash(hash)
      hash.reject { |_key, value| value.nil? || value == {} }
    end

    def integer_id(value)
      Integer(value, exception: false)
    end

    def identity_for(event, attributes)
      stable_id = event['node_id'] || event['id']
      return "github:#{stable_id}" if stable_id.present?

      parts = [attributes[:event_type], attributes[:actor_login], attributes[:occurred_at],
               attributes[:before_metadata], attributes[:after_metadata], attributes[:source_context]]
      "digest:#{Digest::SHA256.hexdigest(Oj.dump(parts, mode: :strict))}"
    end

    def finish_complete(snapshot, generation, events)
      outcome = :superseded
      snapshot.with_lock do
        next unless snapshot.generation == generation

        events.each do |attributes|
          snapshot.metadata_events.find_or_initialize_by(
            github_identity: attributes[:github_identity]
          ).update!(attributes)
        end
        snapshot.update!(status: 'complete', total_count: snapshot.metadata_events.count,
                         refreshed_at: Time.current, failed_at: nil)
        outcome = :complete
      end
      Result.new(snapshot: snapshot.reload, outcome: outcome)
    rescue ActiveRecord::RecordNotFound
      Result.new(snapshot: nil, outcome: :superseded)
    end

    def finish_incomplete(snapshot, generation, error = nil)
      Rails.logger.warn("Metadata timeline incomplete for subject #{subject.id}: #{error.message}") if error
      update_status_if_current(snapshot, generation, status: 'incomplete', failed_at: Time.current)
      Result.new(snapshot: snapshot&.reload, outcome: :incomplete)
    rescue ActiveRecord::RecordNotFound
      Result.new(snapshot: nil, outcome: :superseded)
    end

    def finish_failed(snapshot, generation, error)
      Rails.logger.warn("Metadata timeline refresh failed for subject #{subject.id}: #{error.class}")
      update_status_if_current(snapshot, generation, status: 'stale', failed_at: Time.current) if snapshot
      Result.new(snapshot: snapshot&.reload, outcome: :stale)
    rescue ActiveRecord::RecordNotFound
      Result.new(snapshot: nil, outcome: :superseded)
    end

    def update_status_if_current(snapshot, generation, attributes)
      snapshot.with_lock do
        snapshot.update!(attributes) if snapshot.generation == generation
      end
    rescue ActiveRecord::RecordNotFound
      nil
    end

    def withhold_private_data
      subject.metadata_event_snapshots.where(scope_key: "viewer:#{viewer&.id}").destroy_all if viewer
      subject.metadata_event_snapshots.publicly_visible.destroy_all
      Result.new(snapshot: nil, outcome: :withheld)
    end

    def revoke_snapshot(snapshot, generation)
      snapshot&.with_lock { snapshot.destroy! if snapshot.generation == generation }
      Result.new(snapshot: nil, outcome: :withheld)
    rescue ActiveRecord::RecordNotFound
      Result.new(snapshot: nil, outcome: :superseded)
    end
  end
end
