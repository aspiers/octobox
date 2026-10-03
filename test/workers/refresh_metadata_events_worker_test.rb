# frozen_string_literal: true

require 'test_helper'

class RefreshMetadataEventsWorkerTest < ActiveSupport::TestCase
  setup do
    @repository = create(:repository, private: false)
    @subject = create(:subject, repository: @repository)
  end

  test 'refreshes an existing subject' do
    service = mock
    service.expects(:call).once
    MetadataEvents::Refresh.expects(:new).with(subject: @subject, viewer: nil).returns(service)

    RefreshMetadataEventsWorker.new.perform(@subject.id)
  end

  test 'does nothing after the subject was deleted' do
    MetadataEvents::Refresh.expects(:new).never

    RefreshMetadataEventsWorker.new.perform(-1)
  end

  test 'enqueues only when background jobs are enabled' do
    with_background_jobs_enabled(enabled: false) do
      RefreshMetadataEventsWorker.enqueue(@subject)
      assert_empty RefreshMetadataEventsWorker.jobs
    end

    with_background_jobs_enabled(enabled: true) do
      RefreshMetadataEventsWorker.enqueue(@subject)
      assert_sidekiq_job_enqueued(RefreshMetadataEventsWorker, @subject.id, nil)
    end
  end

  test 'schedules one viewer-scoped refresh per authorized private viewer' do
    @repository.update!(private: true)
    first = create(:user)
    second = create(:user)
    create(:notification, user: first, subject_url: @subject.url,
                          repository_full_name: @repository.full_name)
    create(:notification, user: second, subject_url: @subject.url,
                          repository_full_name: @repository.full_name)
    public_snapshot = create(:metadata_event_snapshot, subject: @subject)

    with_background_jobs_enabled(enabled: true) do
      RefreshMetadataEventsWorker.schedule_for(@subject, private_repository: true)
    end

    refute MetadataEventSnapshot.exists?(public_snapshot.id)
    assert_sidekiq_job_enqueued(RefreshMetadataEventsWorker, @subject.id, first.id)
    assert_sidekiq_job_enqueued(RefreshMetadataEventsWorker, @subject.id, second.id)
    assert_equal 2, RefreshMetadataEventsWorker.jobs.length
  end
end
