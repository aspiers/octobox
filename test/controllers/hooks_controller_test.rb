# frozen_string_literal: true

require 'test_helper'

class HooksControllerTest < ActionController::TestCase
  test 'labels webhook payload' do
    repository = create(:repository, github_id: 139431141)
    notification = create(:notification, repository_full_name: repository.full_name)
    subject = create(:subject, repository: repository, url: notification.subject_url)
    create(:label, subject: subject, name: ':carrot:')
    Notification.any_instance.expects(:update_subject)
    send_webhook 'label'
  end

  test 'github_app_authorization webhook payload' do
    user = create(:user, app_token: 'abcdefg', github_id: 1060)
    send_webhook 'github_app_authorization'
    user.reload
    assert_nil user.app_token
  end

  test 'installation_repositories webhook payload' do
    stub_access_tokens_request
    create(:app_installation, github_id: 293804)
    send_webhook 'installation_repositories'
    assert_equal Repository.count, 1
  end

  test 'installation webhook payload' do
    stub_access_tokens_request
    send_webhook 'installation'
    assert_equal AppInstallation.count, 1
  end

  test 'installation new_permissions_accepted webhook payload' do
    stub_access_tokens_request
    app = create(:app_installation, github_id: 293804, permission_pull_requests: 'read')
    response = { status: 200, body: file_fixture('app_installation.json'), headers: { 'Content-Type' => 'application/json' } }
    stub_request(:get, "https://api.github.com/app/installations/293804").and_return(response)
    send_webhook 'installation', 'installation_update'
    app.reload
    assert_equal app.permission_pull_requests, "write"
  end

  test 'issues webhook payload' do
    send_webhook 'issues'
    assert_equal Subject.count, 1
  end

  test 'pull_request webhook payload' do
    send_webhook 'pull_request'
    assert_equal Subject.count, 1
  end

  test 'pull_request_review webhook payload' do
    send_webhook 'pull_request_review'
    assert_equal Subject.count, 1
  end

  test 'pull_request_review_comment webhook payload' do
    send_webhook 'pull_request_review_comment'
    assert_equal Subject.count, 1
  end

  test 'pull_request_review_thread webhook refreshes review conversations' do
    send_webhook 'pull_request_review_thread', 'pull_request_review_comment'
    assert_equal Subject.count, 1
  end

  test 'deleted pull request review comment webhook triggers snapshot reconciliation' do
    payload = Oj.load(File.read(Rails.root.join('test/fixtures/github_webhooks/pull_request_review_comment.json')))
    payload['action'] = 'deleted'
    SyncReviewsWorker.expects(:perform_async_if_configured).with(payload['pull_request']).once
    @request.headers['X-GitHub-Event'] = 'pull_request_review_comment'

    post :create, body: Oj.dump(payload)

    assert_response :success
  end

  test 'issue_comment webhook payload' do
    send_webhook 'issue_comment'
    assert_equal Subject.count, 1
  end

  test 'private issue comment preserves lifecycle purging and reaction worker options' do
    webhook_payload = Oj.load(File.read(file_fixture('../github_webhooks/issue_comment.json')))
    webhook_payload['repository']['private'] = true
    webhook_payload['action'] = 'deleted'
    LifecycleEventSnapshot.expects(:purge_public_for_subject_url).with(webhook_payload['issue']['url'])
    SyncSubjectWorker.expects(:perform_async_if_configured).with(
      webhook_payload['issue'],
      {
        'comment' => webhook_payload['comment'],
        'action' => 'deleted',
        'repository_id' => webhook_payload['repository']['id'],
        'refresh_lifecycle' => false,
        'refresh_metadata' => false,
        'private_repository' => true
      }
    )

    @request.headers['X-GitHub-Event'] = 'issue_comment'
    post :create, body: Oj.dump(webhook_payload)

    assert_response :success
  end

  test 'deployment webhook queues a targeted commit refresh' do
    RefreshDeploymentActivityForCommitWorker.expects(:perform_async_if_configured).
      with('octobox/octobox', 'a10867b14bb761a232cd80139fbd4c0d33264240')

    send_webhook 'deployment'
  end

  test 'deployment status webhook queues a targeted commit refresh' do
    RefreshDeploymentActivityForCommitWorker.expects(:perform_async_if_configured).
      with('octobox/octobox', 'a10867b14bb761a232cd80139fbd4c0d33264240')

    send_webhook 'deployment_status'
  end

  test 'status webhook payload' do
    stub_notifications_request
    stub_repository_request
    user = create(:user)
    notification = create(:notification, user: user)
    subject = create(:subject, repository_full_name: 'Codertocat/Hello-World',
                               sha: 'a10867b14bb761a232cd80139fbd4c0d33264240',
                               url: notification.subject_url)

    statuses_url = "https://api.github.com/repos/Codertocat/Hello-World/commits/a10867b14bb761a232cd80139fbd4c0d33264240/status"
    response = { status: 200, body: file_fixture('status_request.json'), headers: { 'Content-Type' => 'application/json' } }
    stub_request(:get, statuses_url).and_return(response)

    send_webhook 'status'
    subject.reload
    assert_equal subject.status, 'failure'
  end

  test 'repository webhook payload' do
    send_webhook 'repository'
    assert_equal Repository.count, 1
  end

  test 'reopened issue webhook requests a lifecycle refresh' do
    body = File.read(file_fixture('../github_webhooks/issues.json'))
    webhook_payload = Oj.load(body)
    SyncSubjectWorker.expects(:perform_async_if_configured).with(
      webhook_payload['issue'],
      { 'refresh_lifecycle' => true, 'refresh_metadata' => false, 'private_repository' => true }
    )

    @request.headers['X-GitHub-Event'] = 'issues'
    post :create, body: body

    assert_response :success
  end

  test 'private issue webhook purges public lifecycle data before scheduling' do
    webhook_payload = Oj.load(File.read(file_fixture('../github_webhooks/issues.json')))
    webhook_payload['repository']['private'] = true
    repository = create(
      :repository,
      github_id: webhook_payload['repository']['id'],
      full_name: webhook_payload['repository']['full_name'],
      private: false
    )
    subject = create(
      :subject,
      url: webhook_payload['issue']['url'],
      repository: repository
    )
    snapshot = create(:lifecycle_event_snapshot, subject: subject)
    create(:lifecycle_event, lifecycle_event_snapshot: snapshot)
    SyncSubjectWorker.stubs(:perform_async_if_configured)

    @request.headers['X-GitHub-Event'] = 'issues'
    post :create, body: Oj.dump(webhook_payload)

    assert_response :success
    refute LifecycleEventSnapshot.exists?(snapshot.id)
    assert repository.reload.private?
  end

  test 'push webhook refreshes lifecycle events for repository subjects' do
    webhook_payload = {
      'ref' => 'refs/heads/main',
      'repository' => {
        'id' => 91_001,
        'full_name' => 'octobox/webhook-example',
        'private' => false
      }
    }
    RefreshRepositoryLifecycleEventsWorker.expects(:perform_async_if_configured)
      .with('octobox/webhook-example', false, true)

    @request.headers['X-GitHub-Event'] = 'push'
    post :create, body: Oj.dump(webhook_payload)

    assert_response :success
  end

  test 'tag delete webhook does not refresh lifecycle events' do
    webhook_payload = {
      'ref_type' => 'tag',
      'repository' => {
        'id' => 91_002,
        'full_name' => 'octobox/webhook-tags',
        'private' => false
      }
    }
    RefreshRepositoryLifecycleEventsWorker.expects(:perform_async_if_configured).never

    @request.headers['X-GitHub-Event'] = 'delete'
    post :create, body: Oj.dump(webhook_payload)

    assert_response :success
  end

  test 'metadata issue action requests a subject-scoped refresh' do
    webhook_payload = Oj.load(File.read(file_fixture('../github_webhooks/issues.json')))
    webhook_payload['action'] = 'labeled'
    SyncSubjectWorker.expects(:perform_async_if_configured).with(
      webhook_payload['issue'],
      { 'refresh_lifecycle' => false, 'refresh_metadata' => true, 'private_repository' => true }
    )

    @request.headers['X-GitHub-Event'] = 'issues'
    post :create, body: Oj.dump(webhook_payload)

    assert_response :success
  end

  test 'title edit requests metadata refresh but lifecycle action does not' do
    webhook_payload = Oj.load(File.read(file_fixture('../github_webhooks/issues.json')))
    webhook_payload['action'] = 'edited'
    webhook_payload['changes'] = { 'title' => { 'from' => 'Old title' } }
    SyncSubjectWorker.expects(:perform_async_if_configured).with(
      webhook_payload['issue'],
      { 'refresh_lifecycle' => false, 'refresh_metadata' => true, 'private_repository' => true }
    )

    @request.headers['X-GitHub-Event'] = 'issues'
    post :create, body: Oj.dump(webhook_payload)

    webhook_payload['action'] = 'reopened'
    webhook_payload.delete('changes')
    SyncSubjectWorker.expects(:perform_async_if_configured).with(
      webhook_payload['issue'],
      { 'refresh_lifecycle' => true, 'refresh_metadata' => false, 'private_repository' => true }
    )
    post :create, body: Oj.dump(webhook_payload)

    assert_response :success
  end

  test 'private issue webhook purges public metadata before scheduling' do
    webhook_payload = Oj.load(File.read(file_fixture('../github_webhooks/issues.json')))
    repository = create(:repository, github_id: webhook_payload.dig('repository', 'id'),
                                     full_name: webhook_payload.dig('repository', 'full_name'),
                                     private: false)
    subject = create(:subject, repository: repository, url: webhook_payload.dig('issue', 'url'))
    snapshot = create(:metadata_event_snapshot, subject: subject)
    create(:metadata_event, metadata_event_snapshot: snapshot)
    SyncSubjectWorker.stubs(:perform_async_if_configured)

    @request.headers['X-GitHub-Event'] = 'issues'
    post :create, body: Oj.dump(webhook_payload)

    refute MetadataEventSnapshot.exists?(snapshot.id)
    assert repository.reload.private?
  end

  test 'repository privatization purges public metadata without repository-wide refresh' do
    repository = create(:repository, full_name: 'octobox/private-now')
    subject = create(:subject, repository: repository)
    snapshot = create(:metadata_event_snapshot, subject: subject)
    create(:metadata_event, metadata_event_snapshot: snapshot)
    payload = {
      'action' => 'privatized',
      'repository' => { 'id' => repository.github_id, 'full_name' => repository.full_name, 'private' => true }
    }
    SyncRepositoryWorker.stubs(:perform_async_if_configured)
    RefreshMetadataEventsWorker.expects(:perform_async_if_configured).never

    @request.headers['X-GitHub-Event'] = 'repository'
    post :create, body: Oj.dump(payload)

    assert_response :success
    refute MetadataEventSnapshot.exists?(snapshot.id)
  end

  test 'push webhook does not amplify into repository-wide metadata refreshes' do
    SyncSubjectWorker.expects(:perform_async_if_configured).never
    RefreshMetadataEventsWorker.expects(:perform_async_if_configured).never

    @request.headers['X-GitHub-Event'] = 'push'
    post :create, body: Oj.dump(
      'ref' => 'refs/heads/main',
      'repository' => { 'full_name' => 'octobox/octobox', 'private' => false }
    )

    assert_response :success
  end

  test 'accepts webhook with valid signature when secret is configured' do
    Octobox.config.stubs(:github_webhook_secret).returns('mysecret')
    body = File.read("#{Rails.root}/test/fixtures/github_webhooks/github_app_authorization.json")

    @request.headers['X-Hub-Signature'] = "sha1=#{OpenSSL::HMAC.hexdigest(OpenSSL::Digest.new('sha1'), 'mysecret', body)}"
    @request.headers['X-GitHub-Event'] = 'github_app_authorization'
    post :create, body: body

    assert_response :success
  end

  test 'rejects webhook with invalid signature when secret is configured' do
    Octobox.config.stubs(:github_webhook_secret).returns('mysecret')
    body = File.read("#{Rails.root}/test/fixtures/github_webhooks/github_app_authorization.json")

    @request.headers['X-Hub-Signature'] = "sha1=#{'0' * 40}"
    @request.headers['X-GitHub-Event'] = 'github_app_authorization'

    assert_raises ActiveSupport::MessageVerifier::InvalidSignature do
      post :create, body: body
    end
  end

  test 'rejects webhook with missing signature header when secret is configured' do
    Octobox.config.stubs(:github_webhook_secret).returns('mysecret')
    body = File.read("#{Rails.root}/test/fixtures/github_webhooks/github_app_authorization.json")

    @request.headers['X-GitHub-Event'] = 'github_app_authorization'

    assert_raises ActiveSupport::MessageVerifier::InvalidSignature do
      post :create, body: body
    end
  end
end

def send_webhook(event_type, fixture = nil)
  fixture = event_type if fixture.nil?
  @request.headers['X-GitHub-Event'] = event_type
  Sidekiq.testing!(:inline) do
    inline_sidekiq_status do
      post :create, body: File.read("#{Rails.root}/test/fixtures/github_webhooks/#{fixture}.json")
    end
  end
  assert_response :success
end
