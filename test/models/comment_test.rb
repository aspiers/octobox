# frozen_string_literal: true
require 'test_helper'

class CommentTest < ActiveSupport::TestCase
  include ActionCable::TestHelper

  test 'uses a native review URL when it is safe' do
    comment = build(
      :comment,
      html_url: 'https://github.com/octobox/octobox/pull/42#discussion_r301',
      activity_kind: 'pull_request_review_comment'
    )

    assert_equal 'https://github.com/octobox/octobox/pull/42#discussion_r301', comment.web_url
    assert comment.review_comment?
    refute comment.issue_comment?
  end

  test 'rejects an unsafe native URL' do
    subject = create(:subject, html_url: 'https://github.com/octobox/octobox/pull/42')
    comment = build(:comment, subject: subject, github_id: 301, html_url: 'javascript:alert(1)')

    assert_equal 'https://github.com/octobox/octobox/pull/42#issuecomment-301', comment.web_url
  end

  test 'uses activity-specific anchors for legacy rows without native URLs' do
    subject = create(:subject, html_url: 'https://github.com/octobox/octobox/pull/42')

    expected_urls = {
      'pull_request_review' => 'https://github.com/octobox/octobox/pull/42#pullrequestreview-301',
      'pull_request_review_comment' => 'https://github.com/octobox/octobox/pull/42#discussion_r301',
      'issue_comment' => 'https://github.com/octobox/octobox/pull/42#issuecomment-301'
    }

    expected_urls.each do |activity_kind, expected_url|
      comment = build(:comment, subject: subject, github_id: 301, html_url: nil, activity_kind: activity_kind)
      assert_equal expected_url, comment.web_url
    end
  end

  test 'does not send review rows through the generic comment broadcast' do
    subject = create(:subject)
    stream = CommentsChannel.broadcasting_for(subject)

    assert_no_broadcasts(stream) do
      review = create(
        :comment,
        subject: subject,
        activity_kind: 'pull_request_review',
        body: 'review body'
      )
      review.update!(body: 'updated review body')
    end
  end

  test 'recognizes review submissions and timeline activity' do
    review = build(:comment, activity_kind: 'pull_request_review')
    request = build(:comment, activity_kind: 'review_requested')

    assert review.review_submission?
    assert request.review_activity?
  end
end
