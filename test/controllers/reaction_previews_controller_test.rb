# frozen_string_literal: true
require 'test_helper'

class ReactionPreviewsControllerTest < ActionDispatch::IntegrationTest
  setup do
    Octobox.config.stubs(:github_app).returns(false)
    stub_background_jobs_enabled(value: false)
    stub_fetch_subject_enabled(value: false)
    stub_notifications_request
    stub_repository_request
    stub_comments_requests
    @user = create(:user)
    sign_in_as(@user)
  end

  test 'shows subject and comment reaction chips beside their bodies' do
    notification = create(:notification, user: @user)
    subject = create(
      :subject,
      url: notification.subject_url,
      body: 'Subject body',
      comment_count: 1,
      reactions: {'+1' => 2}
    )
    create(:comment, subject: subject, body: 'Comment body', reactions: {'heart' => 3})

    get notification_path(notification)

    assert_response :success
    assert_select '.discussion-thread .reaction-chips', count: 2
    assert_select '.reaction-chip[aria-label="thumbs up: 2 reactions"]', count: 1
    assert_select '.reaction-chip[aria-label="heart: 3 reactions"]', count: 1
  end

  test 'does not expose reactions when a shared private subject is not displayable' do
    Octobox.stubs(:io?).returns(true)
    notification = create(:notification, user: @user)
    repository = Repository.find_or_create_by!(full_name: notification.repository_full_name) do |record|
      record.github_id = 139431141
    end
    repository.update!(private: true)
    create(
      :subject,
      repository: repository,
      url: notification.subject_url,
      body: 'private body',
      reactions: {'heart' => 7}
    )

    get notification_path(notification)

    assert_response :success
    assert_select '.discussion-thread', count: 0
    assert_select '.reaction-chip', count: 0
    refute_includes response.body, 'heart: 7 reactions'
  end
end
