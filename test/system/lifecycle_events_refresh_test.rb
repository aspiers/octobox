# frozen_string_literal: true

require 'application_system_test_case'

class LifecycleEventsRefreshSystemTest < ApplicationSystemTestCase
  setup do
    Octobox.config.stubs(:background_jobs_enabled).returns(true)
    Octobox.config.stubs(:include_comments).returns(true)
    @user = create(:user)
    repository = create(:repository, full_name: 'octobox/octobox', private: false)
    @subject = create(:subject, repository: repository, comment_count: nil)
    @notification = create(:notification, user: @user, subject_url: @subject.url,
                           repository_full_name: repository.full_name, subject_type: 'Issue')
    sign_in_as(@user)
  end

  test 'a first view fills in lifecycle activity once the background refresh completes' do
    find("#notification-#{@notification.id} .thread-link").click

    assert_selector '.lifecycle-events[data-refresh-pending]', text: 'Checking GitHub for activity'
    assert_no_selector '.lifecycle-event'

    # Simulate the background worker finishing after the first render.
    snapshot = create(:lifecycle_event_snapshot, subject: @subject)
    create(:lifecycle_event, lifecycle_event_snapshot: snapshot, actor_login: 'linear-code[bot]',
           state_reason: 'not_planned')

    assert_selector '.lifecycle-event[data-event-type="closed"]',
                    text: /linear-code\[bot\]\s+closed this issue\s+as not planned/, wait: 10
    assert_no_selector '.lifecycle-events[data-refresh-pending]'
    assert_no_text 'Checking GitHub for activity'
  end

  test 'background completion interleaves new activity with comments without reloading' do
    @subject.update!(comment_count: 2)
    start = Time.utc(2026, 1, 1)
    earlier = create(:comment, subject: @subject, created_at: start)
    later = create(:comment, subject: @subject, created_at: start + 2.minutes)
    find("#notification-#{@notification.id} .thread-link").click
    assert_selector '.lifecycle-events[data-refresh-pending]'
    assert_selector "#comment-#{earlier.id}"
    assert_selector "#comment-#{later.id}"

    snapshot = create(:lifecycle_event_snapshot, subject: @subject)
    create(:lifecycle_event, lifecycle_event_snapshot: snapshot, event_type: 'merged',
           github_identity: 'github:async-merge', occurred_at: start + 1.minute)

    assert_selector '.lifecycle-event[data-event-identity="github:async-merge"]', wait: 10
    assert_equal ["comment-#{earlier.id}", 'github:async-merge', "comment-#{later.id}"], conversation_identities
    assert_no_selector '.lifecycle-events[data-refresh-pending]'
  end

  test 'background completion preserves an expanded mixed conversation' do
    @subject.update!(comment_count: 6)
    start = Time.utc(2026, 1, 1)
    comments = 6.times.map { |index| create(:comment, subject: @subject, created_at: start + index.minutes) }
    visit expand_comments_notification_path(@notification)
    assert_selector '.lifecycle-events[data-refresh-pending]'
    assert_selector '.notification-conversation .card-comment', count: 6

    snapshot = create(:lifecycle_event_snapshot, subject: @subject)
    create(:lifecycle_event, lifecycle_event_snapshot: snapshot,
           github_identity: 'github:expanded-refresh', occurred_at: start + 30.seconds)

    assert_selector '.lifecycle-event[data-event-identity="github:expanded-refresh"]', wait: 10
    expected = comments.map { |comment| "comment-#{comment.id}" }
    expected.insert(1, 'github:expanded-refresh')
    assert_equal expected, conversation_identities
    assert_no_selector '#more-comments'
  end

  private

  def conversation_identities
    all('.notification-conversation .card-comment[id], .notification-conversation .lifecycle-event').map do |node|
      node[:id].presence || node['data-event-identity']
    end
  end
end
