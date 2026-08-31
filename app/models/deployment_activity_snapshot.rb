# frozen_string_literal: true

class DeploymentActivitySnapshot < ApplicationRecord
  DISPLAY_LIMIT = 50
  REFRESH_AFTER = 5.minutes
  REQUEST_TIMEOUT = 1.minute
  AUTHORIZATION_TYPES = %w[public user installation].freeze

  belongs_to :subject

  validates :authorization_type, inclusion: { in: AUTHORIZATION_TYPES }
  validates :authorization_id, absence: true, if: :public_authorization?
  validates :authorization_id, presence: true, unless: :public_authorization?

  class << self
    def for_notification(notification, user)
      return unless notification.user_id == user.id
      return unless notification.subject&.pull_request? && notification.display?

      attributes = { subject: notification.subject, **authorization_attributes(notification.repository, user) }
      create_or_find_by!(attributes)
    end

    def refresh_for_commit(repository_full_name, sha)
      joins(:subject)
        .where(subjects: { repository_full_name: repository_full_name, sha: sha })
        .find_each { |snapshot| snapshot.request_refresh!(force: true) }
    end

    private

    def authorization_attributes(repository, user)
      return { authorization_type: 'public', authorization_id: nil } if repository && !repository.private?
      if repository&.private? && repository.app_installation_id
        return { authorization_type: 'installation', authorization_id: repository.app_installation_id }
      end

      { authorization_type: 'user', authorization_id: user.id }
    end
  end

  def request_refresh!(force: false)
    return unless Octobox.background_jobs_enabled?

    requested_generation = nil

    with_lock do
      now = Time.current
      due = fetched_at.nil? || fetched_at < REFRESH_AFTER.ago
      recently_requested = refresh_requested_at.present? && refresh_requested_at > REQUEST_TIMEOUT.ago
      recent_failure = failed_at.present? && failed_at > REFRESH_AFTER.ago
      next unless force || (due && !recently_requested && !recent_failure)

      requested_generation = generation + 1
      update_columns(generation: requested_generation, refresh_requested_at: now, updated_at: now)
    end

    RefreshDeploymentActivityWorker.perform_async_if_configured(id, requested_generation) if requested_generation

    requested_generation
  end

  def authorized_client
    case authorization_type
    when 'public'
      public_client
    when 'installation'
      installation_client
    when 'user'
      user_client
    end
  end

  def apply_result!(result, expected_generation)
    with_lock do
      return false unless generation == expected_generation

      refreshed_events = result.complete ? result.events : merge_incomplete_events(result.events)
      refreshed_total = result.complete ? result.total_count : [total_count, result.total_count, refreshed_events.length].max
      update!(events: refreshed_events,
              total_count: refreshed_total,
              complete: result.complete,
              fetched_at: Time.current,
              refresh_requested_at: nil,
              failed_at: nil)
    end
    true
  end

  def record_failure!(expected_generation)
    with_lock do
      return false unless generation == expected_generation

      update!(complete: false, refresh_requested_at: nil, failed_at: Time.current)
    end
    true
  end

  private

  def public_authorization?
    authorization_type == 'public'
  end

  def merge_incomplete_events(new_events)
    (events + new_events)
      .index_by { |event| event['id'] }
      .values
      .sort_by { |event| event['occurred_at'].to_s }
      .reverse
      .first(DISPLAY_LIMIT)
  end

  def public_client
    repository = subject.repository
    return unless repository && !repository.private?

    repository.app_installation&.github_client || subject.users.with_access_token.first&.github_client ||
      Octokit::Client.new(auto_paginate: false)
  end

  def installation_client
    installation = AppInstallation.find_by(id: authorization_id)
    repository = subject.repository
    return unless installation && repository&.private? && repository.app_installation_id == installation.id

    installation.github_client
  end

  def user_client
    user = User.find_by(id: authorization_id)
    return unless user && subject.repository&.private?
    return unless subject.notifications.exists?(user_id: user.id)

    user.github_client
  end
end
