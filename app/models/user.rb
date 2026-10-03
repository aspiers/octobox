# frozen_string_literal: true
class User < ApplicationRecord
  InvalidGithubAppCredentials = Class.new(StandardError)

  attr_encrypted :access_token, key: Octobox.config.attr_encryption_key
  attr_encrypted :personal_access_token, key: Octobox.config.attr_encryption_key
  attr_encrypted :app_token, key: Octobox.config.attr_encryption_key
  attr_encrypted :app_refresh_token, key: Octobox.config.attr_encryption_key

  has_secure_token :api_token
  has_many :notifications, dependent: :delete_all
  has_many :notification_undo_actions, dependent: :delete_all
  has_many :app_installation_permissions, dependent: :delete_all
  has_many :app_installations, through: :app_installation_permissions
  has_many :pinned_searches, dependent: :delete_all
  has_one :individual_subscription_purchase, foreign_key: :account_id, primary_key: :github_id, class_name: 'SubscriptionPurchase'

  APP_TOKEN_REFRESH_WINDOW = 5.minutes

  ERRORS = {
    refresh_interval_size: [:refresh_interval, 'must be less than 1 day']
  }.freeze

  validates :github_id,    presence: true, uniqueness: true
  validates :encrypted_access_token, uniqueness: true, allow_blank: true
  validates :github_login, presence: true
  validates :refresh_interval, numericality: {
    only_integer: true,
    allow_blank: true,
    greater_than_or_equal_to: 0,
    less_than_or_equal_to: 86_400_000,
    message: ERRORS[:refresh_interval_size][1]
  }
  validates_with PersonalAccessTokenValidator

  scope :not_recently_synced, -> { where('users.last_synced_at < ?', Octobox.config.webhook_sync_throttle.seconds.ago) }
  scope :with_access_token, -> { where.not(encrypted_access_token: nil) }
  scope :with_github_token, -> {
    where.not(encrypted_access_token: nil).or(where.not(encrypted_personal_access_token: nil))
  }
  scope :active, -> { where('users.updated_at > ?', 1.month.ago) }

  after_create :create_default_pinned_searches

  def admin?
    Octobox.config.github_admin_ids.include?(github_id.to_s)
  end

  def github_app_authorized?
    encrypted_app_token.present?
  end

  def refresh_interval=(val)
    val = nil if 0 == val
    super(val)
  end

  def has_personal_plan?
    individual_subscription_purchase && individual_subscription_purchase.private_repositories_enabled?
  end

  # For users who had zero values set before 20170111185505_allow_null_for_last_synced_at_in_users.rb
  # We want their zeros treated like nils
  def refresh_interval
    0 == super ? nil : super
  end

  def self.find_by_auth_hash(auth_hash)
    User.find_by(github_id: auth_hash['uid'])
  end

  def assign_from_auth_hash(auth_hash, app = 'github')
    token_field = app == 'github' ? :access_token : :app_token
    credentials = auth_hash.fetch('credentials')
    validate_github_app_credentials!(credentials) if app == 'github_app'
    github_attributes = {
      github_id: auth_hash['uid'],
      github_login: auth_hash['info']['nickname'],
      token_field => credentials['token']
    }
    if app == 'github_app'
      github_attributes[:app_refresh_token] = credentials['refresh_token']
      expires_at = credentials['expires_at']
      github_attributes[:app_token_expires_at] = expires_at ? Time.zone.at(expires_at.to_i) : nil
    end

    update!(github_attributes)
  end

  def syncing?
    return false unless Octobox.background_jobs_enabled? && sync_job_id
    # We are syncing if we are queued or working, all other states mean we are not working
    [:queued, :working].include?(Sidekiq::Status.status(sync_job_id))
  end

  def sync_notifications
    return true if syncing?
    job_id = SyncNotificationsWorker.perform_async_if_configured(self.id)
    update(sync_job_id: job_id)
    SyncInstallationPermissionsWorker.perform_async_if_configured(self.id) if github_app_authorized?
  end

  def sync_notifications_in_foreground
    download_service.download
    Rails.logger.info("\n\n\033[32m[#{Time.current}] INFO -- #{github_login} synced their notifications\033[0m\n\n")
  rescue Octokit::Unauthorized => e
    Rails.logger.warn("\n\n\033[32m[#{Time.current}] INFO -- #{github_login} failed to sync notifications -- #{e.message}\033[0m\n\n")
  end

  def download_service
    @download_service ||= DownloadService.new(self)
  end

  def github_client
    personal_access_token_client || access_token_client
  end

  def personal_access_token_client
    Octokit::Client.new(access_token: personal_access_token, auto_paginate: true) if personal_access_token_enabled?
  end

  def access_token_client
    Octokit::Client.new(access_token: access_token, auto_paginate: true) if access_token.present?
  end

  def comment_client(comment)
    if app_token.present? && comment.subject.repository.commentable?
      client = app_installation_client
      return client if client
    end
    github_client
  end

  def app_installation_client
    token = app_token_for_client
    Octokit::Client.new(access_token: token, auto_paginate: true) if token.present?
  end

  def github_avatar_url
    "#{Octobox.config.github_domain}/#{github_login}.png"
  end

  # Use the greater of the system minimum or the user's setting
  def effective_refresh_interval
    if Octobox.refresh_interval_enabled? && refresh_interval
      [Octobox.config.minimum_refresh_interval * 60_000, refresh_interval].max
    end
  end

  def effective_access_token
    personal_access_token_enabled? ? personal_access_token : access_token
  end

  def masked_personal_access_token
    personal_access_token.blank? ? '' :
    "#{'*' * 32}#{personal_access_token.slice(-8..-1)}"
  end

  def personal_access_token_enabled?
    Octobox.personal_access_tokens_enabled? && personal_access_token.present?
  end

  def sync_app_installation_access
    return unless github_app_authorized?
    client = app_installation_client
    return unless client

    rejected_encrypted_app_token = encrypted_app_token
    remote_installs = client.find_user_installations
    app_installations = AppInstallation.where(github_id: remote_installs[:installations].map(&:id))
    app_installations.each do |app_installation|
      app_installation_permissions.find_or_create_by(app_installation_id: app_installation.id)
    end
    app_installation_ids = app_installations.map(&:id)
    removed_permissions = app_installation_permissions.reject{|ep| app_installation_ids.include?(ep.app_installation_id) }
    removed_permissions.each(&:destroy)
  rescue Octokit::Unauthorized
    # GitHub rejected the token, so the authorization is gone even though no
    # github_app_authorization webhook told us. Discard it, matching what
    # SyncGithubAppAuthorizationWorker does on an observed revocation: leaving
    # it set would keep github_app_authorized? true, which hides the re-login
    # button that is the only way for the user to recover.
    revoke_app_token!(expected_encrypted_app_token: rejected_encrypted_app_token)
  end

  def revoke_app_token!(expected_encrypted_app_token: nil)
    with_lock do
      return false if expected_encrypted_app_token && encrypted_app_token != expected_encrypted_app_token

      self.app_token = nil
      self.app_refresh_token = nil
      self.app_token_expires_at = nil
      update_columns(
        encrypted_app_token: nil,
        encrypted_app_token_iv: nil,
        encrypted_app_refresh_token: nil,
        encrypted_app_refresh_token_iv: nil,
        app_token_expires_at: nil,
        updated_at: Time.current
      )
    end
  end

  def has_app_installed?(subject)
    subject.repository.app_installation_id && app_token
  end

  def can_comment?(subject)
    return false unless subject.commentable?
    return true if personal_access_token_enabled?
    return true if Octobox.fetch_subject?
    return true if github_app_authorized? && subject.repository && subject.repository.commentable?
    return false
  end

  def create_default_pinned_searches
    pinned_searches.create(query: 'state:closed,merged archived:false', name: 'Archivable')
    pinned_searches.create(query: 'type:pull_request state:open status:success archived:false', name: 'Mergeable')
    pinned_searches.create(query: "type:pull_request author:#{github_login} inbox:true", name: 'My PRs')
  end

  private

  def validate_github_app_credentials!(credentials)
    refreshing = credentials['expires'] || credentials['refresh_token'].present? || credentials['expires_at']
    complete = credentials['token'].present?
    complete &&= credentials['refresh_token'].present? && credentials['expires_at'].present? if refreshing
    return if complete

    raise InvalidGithubAppCredentials, 'Incomplete GitHub App credentials'
  end

  def app_token_for_client
    refresh_app_token_if_needed
    return if app_token_expires_at && app_token_expires_at <= Time.current

    app_token
  end

  def refresh_app_token_if_needed
    return app_token unless app_token_refresh_due?

    with_lock do
      reload
      return app_token unless app_token_refresh_due?

      credentials = GithubAppUserTokenRefresher.new(refresh_token: app_refresh_token).refresh
      persist_app_credentials(credentials)
      credentials.access_token
    end
  rescue OAuth2::Error, Faraday::Error, GithubAppUserTokenRefresher::InvalidResponse => error
    log_app_token_refresh_failure(error)
    app_token unless app_token_expires_at && app_token_expires_at <= Time.current
  end

  def app_token_refresh_due?
    app_refresh_token.present? && app_token_expires_at.present? &&
      app_token_expires_at <= APP_TOKEN_REFRESH_WINDOW.from_now
  end

  def persist_app_credentials(credentials)
    self.app_token = credentials.access_token
    self.app_refresh_token = credentials.refresh_token
    self.app_token_expires_at = credentials.expires_at
    timestamp = Time.current
    update_columns(
      encrypted_app_token: encrypted_app_token,
      encrypted_app_token_iv: encrypted_app_token_iv,
      encrypted_app_refresh_token: encrypted_app_refresh_token,
      encrypted_app_refresh_token_iv: encrypted_app_refresh_token_iv,
      app_token_expires_at: app_token_expires_at,
      updated_at: timestamp
    )
    self.updated_at = timestamp
  end

  def log_app_token_refresh_failure(error)
    event = {
      event: 'github_app_user_token_refresh_failed',
      user_id: id,
      exception: error.class.name
    }
    response = error.respond_to?(:response) ? error.response : nil
    event[:status] = response.status if response.respond_to?(:status)
    Rails.logger.warn(event.to_json)
  end

  public

  IMPORTABLE_NOTIFICATION_FIELDS = %w[archived starred unread muted_at last_read_at].freeze

  def import_notifications(data)
    data.each do |new_notification|
      n = self.notifications.find_by(github_id: new_notification['github_id'])
      next unless n
      n.attributes = new_notification.slice(*IMPORTABLE_NOTIFICATION_FIELDS)
      n.save(touch: false) if n.changed?
    end
  end
end
