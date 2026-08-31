class HooksController < ApplicationController
  LIFECYCLE_ACTIONS = %w[
    closed reopened converted_to_draft ready_for_review synchronize
  ].freeze
  REPOSITORY_LIFECYCLE_EVENTS = %w[push create delete].freeze

  skip_before_action :verify_authenticity_token
  skip_before_action :authenticate_user!
  before_action :authenticate_github_request!

  def create
    case event_header
    when 'issues'
      sync_subject(payload['issue'])
    when 'issue_comment'
      sync_subject(
        payload['issue'],
        {
          'comment' => payload['comment'],
          'action' => payload['action'],
          'repository_id' => payload.dig('repository', 'id')
        }
      )
    when 'pull_request'
      sync_subject(payload['pull_request'])
    when 'pull_request_review', 'pull_request_review_comment', 'pull_request_review_thread'
      SyncReviewsWorker.perform_async_if_configured(payload['pull_request'])
    when 'label'
      SyncLabelWorker.perform_async_if_configured(payload) if payload['action'] == 'edited'
    when 'installation'
      case payload['action']
      when 'created'
        SyncInstallationWorker.perform_async_if_configured(payload)
      when 'new_permissions_accepted'
        UpdateInstallationWorker.perform_async_if_configured(payload['installation']['id'])
      when 'deleted'
        AppInstallation.find_by_github_id(payload['installation']['id']).try(:destroy)
      end
    when 'installation_repositories'
      SyncInstallationRepositoriesWorker.perform_async_if_configured(payload)
    when 'github_app_authorization'
      SyncGithubAppAuthorizationWorker.perform_async_if_configured(payload['sender']['id'])
    when 'marketplace_purchase'
      MarketplacePurchaseWorker.perform_async_if_configured(payload)  if ['purchased', 'cancelled', 'changed'].include?(payload['action'])
    when 'status'
      SyncStatusWorker.perform_async_if_configured(payload['sha'], payload['name'])
    when 'repository'
      SyncRepositoryWorker.perform_async_if_configured(payload['repository'])
      refresh_repository_lifecycle_events if %w[publicized privatized].include?(payload['action'])
    end

    # Outside the case so that other handlers for push, create or delete
    # events cannot shadow the lifecycle refresh.
    if REPOSITORY_LIFECYCLE_EVENTS.include?(event_header) && ref_event_relevant?
      refresh_repository_lifecycle_events(active_only: event_header == 'push')
    end

    head :no_content
  end

  private

  def sync_subject(remote_subject, extra_options = {})
    Repository.sync(payload['repository']) if payload['repository']
    options = extra_options.merge(
      'refresh_lifecycle' => lifecycle_action?,
      'private_repository' => payload.dig('repository', 'private') == true
    )
    LifecycleEventSnapshot.purge_public_for_subject_url(remote_subject['url']) if options['private_repository']
    SyncSubjectWorker.perform_async_if_configured(remote_subject, options)
  end

  def lifecycle_action?
    return true if LIFECYCLE_ACTIONS.include?(payload['action'])

    payload['action'] == 'edited' && payload.dig('changes', 'base').present?
  end

  def refresh_repository_lifecycle_events(active_only: false)
    repository = payload['repository'] || {}
    full_name = repository['full_name']
    return if full_name.blank?

    Repository.sync(repository)
    private_repository = repository['private'] == true
    LifecycleEventSnapshot.purge_public_for_repository(full_name) if private_repository
    RefreshRepositoryLifecycleEventsWorker.perform_async_if_configured(
      full_name,
      private_repository,
      active_only
    )
  end

  def ref_event_relevant?
    return payload['ref'].to_s.start_with?('refs/heads/') if event_header == 'push'

    payload['ref_type'] == 'branch'
  end

  HMAC_DIGEST = OpenSSL::Digest.new('sha1')

  def authenticate_github_request!
    secret = Octobox.config.github_webhook_secret

    return unless secret.present?

    expected_signature = "sha1=#{OpenSSL::HMAC.hexdigest(HMAC_DIGEST, secret, request_body)}"
    unless ActiveSupport::SecurityUtils.secure_compare(signature_header.to_s, expected_signature)
      raise ActiveSupport::MessageVerifier::InvalidSignature
    end
  end

  def request_body
    @request_body ||= (
      request.body.rewind
      request.body.read
    )
  end

  def payload
    @payload ||= Oj.load(request_body)
  end

  def signature_header
    request.headers['X-Hub-Signature']
  end

  def event_header
    request.headers['X-GitHub-Event']
  end
end
