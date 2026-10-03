# frozen_string_literal: true
require 'test_helper'

class ReviewConversationsControllerTest < ActionDispatch::IntegrationTest
  setup do
    Octobox.config.stubs(:github_app).returns(false)
    stub_background_jobs_enabled(value: false)
    stub_fetch_subject_enabled(value: false)
    stub_notifications_request
    stub_repository_request
    @user = create(:user)
    @user.notifications.delete_all
  end

  test 'renders complete review groups safely and reports remaining conversations' do
    sign_in_as(@user)
    notification = create(:notification, user: @user, subject_type: 'PullRequest')
    subject = create(
      :subject,
      notifications: [notification],
      url: 'https://api.github.com/repos/octobox/octobox/pulls/42',
      html_url: 'https://github.com/octobox/octobox/pull/42',
      comment_count: 9
    )
    create(:comment, subject: subject, github_id: 1, activity_kind: 'issue_comment', body: 'old hidden comment', created_at: at_minute(1))
    review = create(
      :comment,
      subject: subject,
      github_id: 101,
      review_github_id: 101,
      activity_kind: 'pull_request_review',
      review_state: 'SUPER_REVIEW',
      body: 'Review summary',
      html_url: 'https://github.com/octobox/octobox/pull/42#pullrequestreview-101',
      created_at: at_minute(2)
    )
    root = create(
      :comment,
      subject: subject,
      github_id: 301,
      review_github_id: 101,
      activity_kind: 'pull_request_review_comment',
      body: "Please escape <script>alert('x')</script>",
      html_url: 'https://github.com/octobox/octobox/pull/42#discussion_r301',
      review_context: {
        'path' => 'lib/example.rb',
        'line' => 10,
        'start_line' => 8,
        'diff_hunk' => "@@ -1 +1 @@\n-unsafe <tag>\n+safe & sound",
        'resolved' => false,
        'outdated' => false,
        'collapsed' => true
      },
      created_at: at_minute(3)
    )
    create(
      :comment,
      subject: subject,
      github_id: 302,
      review_github_id: 103,
      reply_to_github_id: root.github_id,
      activity_kind: 'pull_request_review_comment',
      body: 'Threaded reply',
      html_url: 'https://github.com/octobox/octobox/pull/42#discussion_r302',
      created_at: at_minute(4)
    )
    create(
      :comment,
      subject: subject,
      github_id: 201,
      activity_kind: 'review_requested',
      author: 'maintainer',
      review_context: {'requested_reviewer' => {'login' => 'carol'}},
      created_at: at_minute(5)
    )
    create(
      :comment,
      subject: subject,
      github_id: 202,
      activity_kind: 'review_request_removed',
      author: 'maintainer',
      review_context: {'requested_team' => {'name' => 'Core team'}},
      created_at: at_minute(6)
    )
    create(
      :comment,
      subject: subject,
      github_id: 203,
      activity_kind: 'review_dismissed',
      author: 'maintainer',
      review_context: {
        'dismissed_review' => {
          'state' => 'changes_requested',
          'dismissal_message' => 'Superseded by a new commit'
        }
      },
      created_at: at_minute(7)
    )
    create(:comment, subject: subject, github_id: 2, activity_kind: 'issue_comment', body: 'latest issue comment', created_at: at_minute(8))

    get notification_path(notification)

    assert_response :success
    assert_equal 1, assigns(:comments_left_to_load)
    assert_equal 6, assigns(:conversation_page).total_count
    refute_includes response.body, 'old hidden comment'
    assert_includes response.body, 'Review summary'
    assert_includes response.body, 'submitted a super review'
    assert_includes response.body, 'lib/example.rb (line 8-10)'
    assert_includes response.body, 'Threaded reply'
    assert_includes response.body, 'Unresolved'
    assert_includes response.body, 'Current'
    assert_includes response.body, 'Collapsed'
    assert_includes response.body, 'requested a review from'
    assert_includes response.body, 'removed the review request for'
    assert_includes response.body, 'Superseded by a new commit'
    assert_includes response.body, 'https://github.com/octobox/octobox/pull/42#pullrequestreview-101'
    assert_includes response.body, '&lt;tag&gt;'
    refute_includes response.body, "<script>alert('x')</script>"

    get expand_comments_notification_path(notification)

    assert_response :success
    assert_equal 0, assigns(:comments_left_to_load)
    assert_includes response.body, 'old hidden comment'
    assert_equal review, assigns(:conversation_page).entries.find { |entry| entry.kind == :review }.activity
  end

  test 'does not expose shared-subject review content when the private-content guard rejects the notification' do
    sign_in_as(@user)
    notification = create(:notification, user: @user, subject_type: 'PullRequest')
    subject = create(:subject, notifications: [notification], comment_count: 1)
    create(
      :comment,
      subject: subject,
      github_id: 101,
      activity_kind: 'pull_request_review',
      review_state: 'COMMENTED',
      body: 'secret review content'
    )
    other_user = create(:user)
    create(:notification, user: other_user, subject_url: subject.url, subject_type: 'PullRequest')
    Notification.any_instance.stubs(:display?).returns(false)

    get notification_path(notification)

    assert_response :success
    refute_includes response.body, 'secret review content'
    assert_select '.review-conversation', false

    get expand_comments_notification_path(notification), xhr: true

    assert_response :success
    assert_empty assigns(:conversation_page).entries
    refute_includes response.body, 'secret review content'
  end

  private

  def at_minute(minute)
    Time.zone.parse("2026-01-01 10:#{minute.to_s.rjust(2, '0')}:00")
  end
end
