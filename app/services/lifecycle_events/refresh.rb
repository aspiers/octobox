# frozen_string_literal: true

require 'digest'
require 'uri'

module LifecycleEvents
  class Refresh
    PAGE_SIZE = 100
    MAX_PAGES = 100

    Result = Data.define(:snapshot, :outcome)

    def initialize(subject:, viewer: nil, client: nil)
      @subject = subject
      @viewer = viewer
      @client = client
    end

    def call(force: true)
      return Result.new(snapshot: nil, outcome: :unsupported) unless subject.issue_or_pull_request?
      return withhold_private_data unless authorized_scope?

      subject.lifecycle_event_snapshots.publicly_visible.destroy_all if private_repository?
      existing_snapshot = LifecycleEventSnapshot.find_by(subject: subject, scope_key: scope_key)
      if !force && existing_snapshot&.fresh?
        return Result.new(snapshot: existing_snapshot, outcome: :fresh)
      end

      snapshot, generation = begin_refresh
      remote_events, complete = download_events
      return finish_incomplete(snapshot, generation) unless complete

      finish_complete(snapshot, generation, remote_events)
    rescue Octokit::NotFound
      revoke_snapshot(snapshot, generation)
    rescue Octokit::Unauthorized, Octokit::Forbidden => error
      revoke_private_snapshot(snapshot, generation, error)
    rescue Octokit::ClientError, Faraday::Error, Timeout::Error => error
      finish_failed(snapshot, generation, error)
    end

    private

    attr_reader :subject, :viewer

    def authorized_scope?
      return true unless private_repository?

      viewer&.effective_access_token.present? && subject.notifications.exists?(user_id: viewer.id)
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
        snapshot.update!(
          generation: generation,
          status: 'refreshing',
          refresh_started_at: Time.current,
          failed_at: nil
        )
      end

      [snapshot, generation]
    end

    def find_or_create_snapshot
      LifecycleEventSnapshot.find_or_create_by!(subject: subject, scope_key: scope_key) do |record|
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
        Octokit::Client.new(access_token: viewer.effective_access_token, auto_paginate: false)
      else
        # Shared snapshots must never depend on credentials that can see private data.
        Octokit::Client.new(auto_paginate: false)
      end
    end

    def timeline_url
      subject_uri = URI.parse(subject.url.to_s)
      api_uri = URI.parse(Octobox.config.github_api_prefix)
      valid_origin = subject_uri.scheme == api_uri.scheme &&
        subject_uri.host == api_uri.host &&
        subject_uri.port == api_uri.port &&
        subject_uri.userinfo.nil?
      valid_path = subject_uri.path.match?(%r{\A/repos/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+/(?:issues|pulls)/\d+\z})
      raise IncompleteSnapshot, 'invalid subject timeline URL' unless valid_origin && valid_path

      "#{subject_uri.to_s.sub('/pulls/', '/issues/')}/timeline"
    rescue URI::InvalidURIError
      raise IncompleteSnapshot, 'invalid subject timeline URL'
    end

    def attributes_for(remote_event)
      event = remote_event.to_h.deep_stringify_keys
      event_type = event['event']
      return unless LifecycleEvent::EVENT_TYPES.include?(event_type)

      occurred_at = event['created_at'] || event.dig('committer', 'date') || event.dig('author', 'date')
      return unless occurred_at

      attributes = {
        event_type: event_type,
        actor_login: actor_for(event),
        occurred_at: occurred_at,
        commit_sha: event['commit_id'] || event['sha'],
        before_commit_sha: commit_sha_from(event['before_commit']),
        after_commit_sha: commit_sha_from(event['after_commit']),
        ref_name: event['ref'] || event.dig('head_ref', 'ref') || event.dig('base_ref', 'ref'),
        previous_ref_name: event['previous_ref'] || event.dig('rename', 'from'),
        current_ref_name: event['current_ref'] || event.dig('rename', 'to'),
        commit_message: event['message'],
        github_event_id: integer_id(event['id'])
      }
      attributes[:github_identity] = identity_for(event, attributes)
      attributes
    end

    def actor_for(event)
      event.dig('actor', 'login') ||
        event.dig('author', 'login') || event.dig('author', 'name') ||
        event.dig('committer', 'login') || event.dig('committer', 'name')
    end

    def commit_sha_from(commit)
      commit.is_a?(Hash) ? commit['sha'] || commit[:sha] : commit
    end

    def integer_id(value)
      Integer(value, exception: false)
    end

    def identity_for(event, attributes)
      stable_id = event['node_id'] || event['id']
      return "github:#{stable_id}" if stable_id.present?
      return "commit:#{event['sha']}" if event['event'] == 'committed' && event['sha'].present?

      identity_parts = attributes.values_at(
        :event_type,
        :actor_login,
        :occurred_at,
        :commit_sha,
        :before_commit_sha,
        :after_commit_sha,
        :ref_name,
        :previous_ref_name,
        :current_ref_name
      )
      "digest:#{Digest::SHA256.hexdigest(identity_parts.join("\0"))}"
    end

    def finish_complete(snapshot, generation, events)
      outcome = replace_if_current(snapshot, generation, events)
      Result.new(snapshot: snapshot.reload, outcome: outcome)
    end

    def replace_if_current(snapshot, generation, events)
      outcome = :superseded
      snapshot.with_lock do
        next unless snapshot.generation == generation

        event_identities = events.map { |event| event[:github_identity] }
        events.each do |attributes|
          record = snapshot.lifecycle_events.find_or_initialize_by(
            github_identity: attributes[:github_identity]
          )
          record.update!(attributes)
        end
        if event_identities.empty?
          snapshot.lifecycle_events.delete_all
        else
          snapshot.lifecycle_events.where.not(github_identity: event_identities).delete_all
        end
        snapshot.update!(
          status: 'complete',
          total_count: events.length,
          refreshed_at: Time.current,
          failed_at: nil
        )
        outcome = :complete
      end
      outcome
    end

    def finish_incomplete(snapshot, generation)
      update_status_if_current(snapshot, generation, status: 'incomplete', failed_at: Time.current)
      Result.new(snapshot: snapshot.reload, outcome: :incomplete)
    end

    def finish_failed(snapshot, generation, error)
      Rails.logger.warn("Lifecycle timeline refresh failed for subject #{subject.id}: #{error.class}")
      update_status_if_current(snapshot, generation, status: 'stale', failed_at: Time.current) if snapshot
      Result.new(snapshot: snapshot&.reload, outcome: :stale)
    end

    def update_status_if_current(snapshot, generation, attributes)
      snapshot.with_lock do
        snapshot.update!(attributes) if snapshot.generation == generation
      end
    end

    def withhold_private_data
      subject.lifecycle_event_snapshots.where(scope_key: "viewer:#{viewer&.id}").destroy_all if viewer
      subject.lifecycle_event_snapshots.publicly_visible.destroy_all
      Result.new(snapshot: nil, outcome: :withheld)
    end

    def revoke_snapshot(snapshot, generation)
      snapshot&.with_lock do
        snapshot.destroy! if snapshot.generation == generation
      end
      Result.new(snapshot: nil, outcome: :withheld)
    rescue ActiveRecord::RecordNotFound
      Result.new(snapshot: nil, outcome: :superseded)
    end

    def revoke_private_snapshot(snapshot, generation, error)
      return finish_failed(snapshot, generation, error) unless private_repository?

      revoke_snapshot(snapshot, generation)
    end
  end
end
