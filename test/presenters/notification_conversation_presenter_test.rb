# frozen_string_literal: true
require 'test_helper'

class NotificationConversationPresenterTest < ActiveSupport::TestCase
  test 'groups reviews, root threads, and replies before limiting conversations' do
    subject = create(:subject)
    issue = create(:comment, subject: subject, github_id: 1, activity_kind: 'issue_comment', created_at: at_minute(1))
    review = create(
      :comment,
      subject: subject,
      github_id: 101,
      review_github_id: 101,
      activity_kind: 'pull_request_review',
      review_state: 'CHANGES_REQUESTED',
      created_at: at_minute(2)
    )
    root = create(
      :comment,
      subject: subject,
      github_id: 301,
      review_github_id: 101,
      activity_kind: 'pull_request_review_comment',
      created_at: at_minute(3)
    )
    create(
      :comment,
      subject: subject,
      github_id: 103,
      review_github_id: 103,
      activity_kind: 'pull_request_review',
      review_state: 'COMMENTED',
      body: nil,
      created_at: at_minute(4)
    )
    reply = create(
      :comment,
      subject: subject,
      github_id: 302,
      review_github_id: 103,
      reply_to_github_id: 301,
      activity_kind: 'pull_request_review_comment',
      created_at: at_minute(9)
    )
    request = create(:comment, subject: subject, github_id: 201, activity_kind: 'review_requested', created_at: at_minute(5))
    orphan = create(
      :comment,
      subject: subject,
      github_id: 400,
      review_github_id: 999,
      activity_kind: 'pull_request_review_comment',
      created_at: at_minute(6)
    )
    latest = create(:comment, subject: subject, github_id: 2, activity_kind: 'issue_comment', created_at: at_minute(10))

    page = NotificationConversationPresenter.new(subject).page(limit: 2)

    assert_equal 5, page.total_count
    assert_equal 3, page.remaining_count
    assert_equal [review, latest], page.entries.map(&:activity)

    review_entry = page.entries.first
    assert_equal :review, review_entry.kind
    assert_equal 1, review_entry.threads.length
    assert_equal root, review_entry.threads.first.root
    assert_equal [reply], review_entry.threads.first.replies

    full_page = NotificationConversationPresenter.new(subject).page
    assert_equal [issue, request, orphan, review, latest], full_page.entries.map(&:activity)
    assert_equal 0, full_page.remaining_count
  end

  test 'never presents pending rows regardless of legacy classification' do
    subject = create(:subject)
    [nil, 'issue_comment', 'pull_request_review', 'pull_request_review_comment'].each_with_index do |kind, index|
      create(
        :comment,
        subject: subject,
        github_id: 102 + index,
        review_github_id: 102,
        activity_kind: kind,
        review_state: index.even? ? 'PENDING' : 'pending'
      )
    end

    page = NotificationConversationPresenter.new(subject).page

    assert_empty page.entries
  end

  test 'orders lifecycle events by occurrence time rather than import time with deterministic ties' do
    subject = create(:subject)
    comment = create(:comment, subject: subject, created_at: at_minute(5))
    snapshot = create(:lifecycle_event_snapshot, subject: subject)
    earlier = create(:lifecycle_event, lifecycle_event_snapshot: snapshot,
                     github_identity: 'github:earlier', occurred_at: at_minute(1), created_at: at_minute(20))
    tied = create(:lifecycle_event, lifecycle_event_snapshot: snapshot,
                  github_identity: 'github:tied', occurred_at: at_minute(5), created_at: at_minute(10))
    later = create(:lifecycle_event, lifecycle_event_snapshot: snapshot,
                   github_identity: 'github:later', occurred_at: at_minute(9), created_at: at_minute(2))

    presenter = NotificationConversationPresenter.new(subject, lifecycle_events: [later, tied, earlier])
    assert_equal [earlier, comment, tied, later], presenter.page.entries.map(&:activity)
    page = presenter.page(limit: 2)
    assert_equal [tied, later], page.entries.map(&:activity)
    assert_equal 2, page.remaining_count
    assert_equal 4, page.total_count
  end

  private

  def at_minute(minute)
    Time.zone.parse("2026-01-01 10:#{minute.to_s.rjust(2, '0')}:00")
  end
end
