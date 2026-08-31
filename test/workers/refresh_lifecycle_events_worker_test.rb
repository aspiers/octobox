# frozen_string_literal: true

require 'test_helper'

class RefreshLifecycleEventsWorkerTest < ActiveSupport::TestCase
  test 'refreshes one subject for the requested viewer' do
    subject = create(:subject)
    viewer = create(:user)
    service = mock
    LifecycleEvents::Refresh.expects(:new).with(subject: subject, viewer: viewer).returns(service)
    service.expects(:call)

    RefreshLifecycleEventsWorker.new.perform(subject.id, viewer.id)
  end

  test 'private scheduling purges public data and schedules each authorized viewer' do
    repository = create(:repository, private: true)
    subject = create(:subject, repository: repository)
    access_token_viewer = create(:user)
    stub_personal_access_tokens_enabled
    personal_token_viewer = build(:user, access_token: nil, personal_access_token: 'personal-token')
    stub_user_request(user: personal_token_viewer)
    personal_token_viewer.save!
    unauthorized_viewer = create(:user, access_token: nil)
    [access_token_viewer, personal_token_viewer, unauthorized_viewer].each do |viewer|
      create(
        :notification,
        user: viewer,
        subject_url: subject.url,
        repository_full_name: repository.full_name
      )
    end
    public_snapshot = create(:lifecycle_event_snapshot, subject: subject)
    RefreshLifecycleEventsWorker.expects(:perform_async_if_configured)
      .with(subject.id, access_token_viewer.id)
    RefreshLifecycleEventsWorker.expects(:perform_async_if_configured)
      .with(subject.id, personal_token_viewer.id)

    RefreshLifecycleEventsWorker.schedule_for(subject, private_repository: true)

    refute LifecycleEventSnapshot.exists?(public_snapshot.id)
  end

  test 'repository worker refreshes only issues and pull requests' do
    repository = create(:repository)
    issue = create(:subject, repository: repository)
    commit = create(
      :subject,
      repository: repository,
      url: "https://api.github.com/repos/#{repository.full_name}/commits/abc123"
    )
    RefreshLifecycleEventsWorker.expects(:schedule_for)
      .with(issue, private_repository: false)
    RefreshLifecycleEventsWorker.expects(:schedule_for)
      .with(commit, private_repository: false).never

    RefreshRepositoryLifecycleEventsWorker.new.perform(repository.full_name, false)
  end
end
