# frozen_string_literal: true
require 'test_helper'

class SyncSubjectWorkerTest < ActiveSupport::TestCase
  test 'syncs a webhook comment passed in the options hash' do
    Octobox.stubs(:include_comments?).returns(true)
    subject = create(:subject)
    remote_comment = {'id' => 9001, 'body' => 'Hello'}
    Subject.expects(:sync).with({'url' => subject.url}).returns(subject)
    subject.expects(:sync_issue_comment_event)
           .with(remote_comment, action: 'created', repository_github_id: 123)

    SyncSubjectWorker.new.perform(
      {'url' => subject.url},
      {'comment' => remote_comment, 'action' => 'created', 'repository_id' => 123}
    )
  end

  test 'refreshes lifecycle and metadata without dropping the webhook comment' do
    Octobox.stubs(:include_comments?).returns(true)
    subject = create(:subject)
    remote_comment = {'id' => 9001, 'body' => 'Hello'}
    Subject.expects(:sync).with({'url' => subject.url}).returns(subject)
    RefreshLifecycleEventsWorker.expects(:schedule_for).with(subject, private_repository: false)
    RefreshMetadataEventsWorker.expects(:schedule_for).with(subject, private_repository: false)
    subject.expects(:sync_issue_comment_event)
           .with(remote_comment, action: 'created', repository_github_id: 123)

    SyncSubjectWorker.new.perform(
      {'url' => subject.url},
      {
        'refresh_lifecycle' => true,
        'refresh_metadata' => true,
        'private_repository' => false,
        'comment' => remote_comment,
        'action' => 'created',
        'repository_id' => 123
      }
    )
  end

  test 'syncs only the subject when no comment is given' do
    subject = create(:subject)
    Subject.expects(:sync).with({'url' => subject.url}).returns(subject)
    subject.expects(:sync_issue_comment_event).never

    SyncSubjectWorker.new.perform({'url' => subject.url})
  end
end
