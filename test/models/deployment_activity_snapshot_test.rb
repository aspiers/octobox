# frozen_string_literal: true

require 'test_helper'

class DeploymentActivitySnapshotTest < ActiveSupport::TestCase
  test 'public snapshots are shared between viewers' do
    repository = create(:repository, full_name: 'octobox/public', private: false)
    subject = pull_request_subject(repository)
    first_user = create(:user)
    second_user = create(:user)
    first_notification = pull_request_notification(subject, repository, first_user)
    second_notification = pull_request_notification(subject, repository, second_user)

    first = DeploymentActivitySnapshot.for_notification(first_notification, first_user)
    second = DeploymentActivitySnapshot.for_notification(second_notification, second_user)

    assert_equal first, second
    assert_equal 'public', first.authorization_type
    assert_nil first.authorization_id
  end

  test 'does not create a snapshot for another users notification' do
    repository = create(:repository, full_name: 'octobox/ownership', private: false)
    subject = pull_request_subject(repository)
    owner = create(:user)
    other_user = create(:user)
    notification = pull_request_notification(subject, repository, owner)

    assert_nil DeploymentActivitySnapshot.for_notification(notification, other_user)
    assert_equal 0, subject.deployment_activity_snapshots.count
  end

  test 'private snapshots using viewer tokens never cross users' do
    repository = create(:repository, full_name: 'octobox/private', private: true)
    subject = pull_request_subject(repository)
    first_user = create(:user)
    second_user = create(:user)
    first = DeploymentActivitySnapshot.for_notification(pull_request_notification(subject, repository, first_user), first_user)
    second = DeploymentActivitySnapshot.for_notification(pull_request_notification(subject, repository, second_user), second_user)

    refute_equal first, second
    assert_equal ['user', first_user.id], [first.authorization_type, first.authorization_id]
    assert_equal ['user', second_user.id], [second.authorization_type, second.authorization_id]
    assert_equal first_user.access_token, first.authorized_client.access_token
    assert_equal second_user.access_token, second.authorized_client.access_token
  end

  test 'unknown repository privacy defaults to a viewer-scoped snapshot' do
    user = create(:user)
    subject = create(:subject,
                     repository_full_name: 'missing/private',
                     url: 'https://api.github.com/repos/missing/private/pulls/42')
    notification = create(:notification,
                          user: user,
                          subject_url: subject.url,
                          repository_full_name: subject.repository_full_name,
                          subject_type: 'PullRequest')

    snapshot = DeploymentActivitySnapshot.for_notification(notification, user)

    assert_equal ['user', user.id], [snapshot.authorization_type, snapshot.authorization_id]
    assert_nil snapshot.authorized_client, 'data must not be fetched until repository privacy is known'
  end

  test 'a public snapshot loses authorization if its repository becomes private' do
    repository = create(:repository, full_name: 'octobox/privacy-transition', private: false)
    subject = pull_request_subject(repository)
    user = create(:user)
    snapshot = DeploymentActivitySnapshot.for_notification(pull_request_notification(subject, repository, user), user)

    repository.update!(private: true)

    assert_nil snapshot.authorized_client
  end

  test 'private installation snapshots share only the installation authorization' do
    installation = create(:app_installation)
    repository = create(:repository, full_name: 'octobox/installed-private', private: true, app_installation: installation)
    subject = pull_request_subject(repository)
    first_user = create(:user)
    second_user = create(:user)

    first = DeploymentActivitySnapshot.for_notification(pull_request_notification(subject, repository, first_user), first_user)
    second = DeploymentActivitySnapshot.for_notification(pull_request_notification(subject, repository, second_user), second_user)

    assert_equal first, second
    assert_equal ['installation', installation.id], [first.authorization_type, first.authorization_id]
  end

  test 'generation protects a newer refresh from an older result' do
    repository = create(:repository, full_name: 'octobox/generation', private: false)
    snapshot = DeploymentActivitySnapshot.create!(subject: pull_request_subject(repository), authorization_type: 'public', generation: 2)
    snapshot.update!(events: [{ 'id' => 'new' }], total_count: 1, complete: true)
    stale = DeploymentActivityFetcher::Result.new(events: [{ 'id' => 'old' }], total_count: 1, complete: true)

    refute snapshot.apply_result!(stale, 1)
    assert_equal [{ 'id' => 'new' }], snapshot.reload.events
  end

  test 'incomplete results merge with previously fetched events' do
    repository = create(:repository, full_name: 'octobox/incomplete', private: false)
    snapshot = DeploymentActivitySnapshot.create!(subject: pull_request_subject(repository),
                                                   authorization_type: 'public',
                                                   generation: 4,
                                                   events: [{ 'id' => 'retained', 'occurred_at' => '2026-01-01T00:00:00Z' }],
                                                   total_count: 2,
                                                   complete: true)
    partial = DeploymentActivityFetcher::Result.new(
      events: [{ 'id' => 'new', 'occurred_at' => '2026-01-02T00:00:00Z' }],
      total_count: 1,
      complete: false
    )

    assert snapshot.apply_result!(partial, 4)
    snapshot.reload
    assert_equal %w[new retained], snapshot.events.pluck('id')
    assert_equal 2, snapshot.total_count
    refute snapshot.complete
  end

  test 'API failures preserve events and mark the snapshot incomplete' do
    repository = create(:repository, full_name: 'octobox/failure', private: false)
    snapshot = DeploymentActivitySnapshot.create!(subject: pull_request_subject(repository),
                                                   authorization_type: 'public',
                                                   generation: 3,
                                                   events: [{ 'id' => 'retained' }],
                                                   total_count: 1,
                                                   complete: true)

    assert snapshot.record_failure!(3)
    snapshot.reload
    assert_equal [{ 'id' => 'retained' }], snapshot.events
    assert_equal 1, snapshot.total_count
    refute snapshot.complete
    assert snapshot.failed_at
  end

  test 'recent failures back off unless a webhook forces refresh' do
    repository = create(:repository, full_name: 'octobox/backoff', private: false)
    snapshot = DeploymentActivitySnapshot.create!(subject: pull_request_subject(repository),
                                                   authorization_type: 'public',
                                                   generation: 1,
                                                   failed_at: Time.current)

    with_background_jobs_enabled do
      assert_nil snapshot.request_refresh!
      assert_empty RefreshDeploymentActivityWorker.jobs
      assert_equal 2, snapshot.request_refresh!(force: true)
      assert_sidekiq_job_enqueued(RefreshDeploymentActivityWorker, snapshot.id, 2)
    end
  end

  test 'refresh requests are asynchronous, stale-aware, and generation numbered' do
    repository = create(:repository, full_name: 'octobox/refresh', private: false)
    snapshot = DeploymentActivitySnapshot.create!(subject: pull_request_subject(repository), authorization_type: 'public')

    with_background_jobs_enabled do
      generation = snapshot.request_refresh!
      assert_equal 1, generation
      assert_sidekiq_job_enqueued(RefreshDeploymentActivityWorker, snapshot.id, 1)
      assert_nil snapshot.request_refresh!, 'a recent queued refresh must not be duplicated'
    end
  end

  private

  def pull_request_subject(repository)
    create(:subject,
           repository: repository,
           url: "https://api.github.com/repos/#{repository.full_name}/pulls/42",
           sha: 'a10867b14bb761a232cd80139fbd4c0d33264240')
  end

  def pull_request_notification(subject, repository, user)
    create(:notification,
           user: user,
           subject_url: subject.url,
           repository_full_name: repository.full_name,
           subject_type: 'PullRequest')
  end
end
