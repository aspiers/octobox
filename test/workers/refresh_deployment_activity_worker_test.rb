# frozen_string_literal: true

require 'test_helper'

class RefreshDeploymentActivityWorkerTest < ActiveSupport::TestCase
  setup do
    repository = create(:repository, full_name: 'octobox/worker', private: false)
    @user = create(:user)
    @subject = create(:subject,
                      repository: repository,
                      url: 'https://api.github.com/repos/octobox/worker/pulls/42',
                      sha: 'a10867b14bb761a232cd80139fbd4c0d33264240')
    create(:notification, user: @user, subject: @subject, repository: repository, subject_type: 'PullRequest')
    @snapshot = DeploymentActivitySnapshot.create!(subject: @subject, authorization_type: 'public', generation: 1)
  end

  test 'stores a successful snapshot' do
    result = DeploymentActivityFetcher::Result.new(events: [{ 'id' => 'timeline:1' }], total_count: 1, complete: true)
    DeploymentActivityFetcher.any_instance.expects(:call).returns(result)

    RefreshDeploymentActivityWorker.new.perform(@snapshot.id, 1)

    @snapshot.reload
    assert_equal [{ 'id' => 'timeline:1' }], @snapshot.events
    assert_equal 1, @snapshot.total_count
    assert @snapshot.complete
    assert @snapshot.fetched_at
  end

  test 'does not fetch for an obsolete generation' do
    DeploymentActivityFetcher.any_instance.expects(:call).never

    RefreshDeploymentActivityWorker.new.perform(@snapshot.id, 0)
  end

  test 'retains old data when GitHub fails' do
    @snapshot.update!(events: [{ 'id' => 'retained' }], total_count: 1, complete: true)
    DeploymentActivityFetcher.any_instance.stubs(:call).raises(Octokit::ServerError)

    assert_raises Octokit::ServerError do
      RefreshDeploymentActivityWorker.new.perform(@snapshot.id, 1)
    end

    @snapshot.reload
    assert_equal [{ 'id' => 'retained' }], @snapshot.events
    refute @snapshot.complete
    assert @snapshot.failed_at
  end
end

class RefreshDeploymentActivityForCommitWorkerTest < ActiveSupport::TestCase
  test 'refreshes only snapshots for the webhook repository and SHA' do
    matching_repository = create(:repository, full_name: 'octobox/matching', private: false)
    matching_subject = create(:subject,
                              repository: matching_repository,
                              url: 'https://api.github.com/repos/octobox/matching/pulls/42',
                              sha: 'matching-sha')
    matching = DeploymentActivitySnapshot.create!(subject: matching_subject, authorization_type: 'public')

    other_subject = create(:subject,
                           repository: matching_repository,
                           url: 'https://api.github.com/repos/octobox/matching/pulls/43',
                           sha: 'other-sha')
    other = DeploymentActivitySnapshot.create!(subject: other_subject, authorization_type: 'public')

    with_background_jobs_enabled do
      RefreshDeploymentActivityForCommitWorker.new.perform('octobox/matching', 'matching-sha')
    end

    assert_equal 1, matching.reload.generation
    assert_equal 0, other.reload.generation
    assert_sidekiq_job_enqueued(RefreshDeploymentActivityWorker, matching.id, 1)
  end
end
