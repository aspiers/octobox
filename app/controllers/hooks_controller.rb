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
      enqueue_reference_refresh(payload.dig('repository', 'full_name'), payload.dig('issue', 'title'), payload.dig('issue', 'body'))
    when 'issue_comment'
      sync_subject(
        payload['issue'],
        {
          'comment' => payload['comment'],
          'action' => payload['action'],
          'repository_id' => payload.dig('repository', 'id')
        }
      )
      enqueue_reference_refresh(payload.dig('repository', 'full_name'), payload.dig('comment', 'body'))
    when 'pull_request'
      sync_subject(payload['pull_request'])
      enqueue_reference_refresh(payload.dig('repository', 'full_name'), payload.dig('pull_request', 'title'), payload.dig('pull_request', 'body'))
    when 'pull_request_review', 'pull_request_review_comment', 'pull_request_review_thread'
      SyncReviewsWorker.perform_async_if_configured(payload['pull_request'])
      enqueue_reference_refresh(
        payload.dig('repository', 'full_name'),
        payload.dig('review', 'body'),
        payload.dig('comment', 'body')
      )
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
      SyncStatusWorker.perform_async_if_configured(payload['sha'], payload.dig('repository', 'full_name') || payload['name'])
    when 'check_run'
      SyncStatusWorker.perform_async_if_configured(payload.dig('check_run', 'head_sha'), payload.dig('repository', 'full_name'))
    when 'check_suite'
      SyncStatusWorker.perform_async_if_configured(payload.dig('check_suite', 'head_sha'), payload.dig('repository', 'full_name'))
    when 'push'
      enqueue_reference_refresh(
        payload.dig('repository', 'full_name'),
        *Array(payload['commits']).map { |commit| commit['message'] }
      )
    when 'repository'
      SyncRepositoryWorker.perform_async_if_configured(payload['repository'])
      purge_reference_activity_for_private_repository
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

  def enqueue_reference_refresh(repository_full_name, *texts)
    return if payload.dig('repository', 'private')
    return if repository_full_name.blank? || texts.compact.empty?

    SyncReferencedSubjectsWorker.perform_async_if_configured(repository_full_name, texts.compact)
  end

  def purge_reference_activity_for_private_repository
    repository = payload['repository'] || {}
    return unless repository['private'] || %w[privatized deleted].include?(payload['action'])

    ReferenceActivity.where(source_repository_full_name: repository['full_name']).delete_all
  end

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
