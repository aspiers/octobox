class HooksController < ApplicationController
  skip_before_action :verify_authenticity_token
  skip_before_action :authenticate_user!
  before_action :authenticate_github_request!

  def create
    case event_header
    when 'issues'
      SyncSubjectWorker.perform_async_if_configured(payload['issue'])
      enqueue_reference_refresh(payload.dig('repository', 'full_name'), payload.dig('issue', 'title'), payload.dig('issue', 'body'))
    when 'issue_comment'
      SyncSubjectWorker.perform_async_if_configured(
        payload['issue'],
        {
          'comment' => payload['comment'],
          'action' => payload['action'],
          'repository_id' => payload.dig('repository', 'id')
        }
      )
      enqueue_reference_refresh(payload.dig('repository', 'full_name'), payload.dig('comment', 'body'))
    when 'pull_request'
      SyncSubjectWorker.perform_async_if_configured(payload['pull_request'])
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
    end

    head :no_content
  end

  private

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
