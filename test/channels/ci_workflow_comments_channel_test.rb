# frozen_string_literal: true
require 'test_helper'

class CiWorkflowCommentsChannelTest < ActionCable::Channel::TestCase
  tests CommentsChannel

  setup do
    @user = create(:user)
    stub_connection current_user: @user
  end

  test 'rejects nil-subject CheckSuite without accessing Subject' do
    notification = create(:notification, user: @user, subject_type: 'CheckSuite',
      subject_url: 'https://github.com/octobox/octobox/actions')
    Notification.any_instance.expects(:subject).never

    subscribe notification: notification.id

    assert subscription.rejected?
    assert_no_streams
  end

  test 'rejects CheckSuite even when an accidental shared Subject exists' do
    notification = create(:notification, user: @user, subject_type: 'CheckSuite',
      subject_url: 'https://github.com/octobox/octobox/actions')
    create(:subject, notifications: [notification], body: 'Unrelated private content')
    Notification.any_instance.expects(:subject).never

    subscribe notification: notification.id

    assert subscription.rejected?
    assert_no_streams
  end

  test 'rejects a restricted private notification before accessing Subject' do
    notification = create(:notification, user: @user)
    create(:repository, full_name: notification.repository_full_name, private: true)
    create(:subject, notifications: [notification])
    Octobox.stubs(:io?).returns(true)
    Repository.any_instance.stubs(:display_subject?).returns(false)
    User.any_instance.stubs(:has_personal_plan?).returns(false)
    Notification.any_instance.expects(:subject).never

    subscribe notification: notification.id

    assert subscription.rejected?
    assert_no_streams
  end

  test 'rejects notifications owned by another user without raising' do
    notification = create(:notification)
    create(:subject, notifications: [notification])
    Notification.any_instance.expects(:subject).never

    subscribe notification: notification.id

    assert subscription.rejected?
    assert_no_streams
  end

  test 'rejects missing notification without raising' do
    subscribe notification: 'missing'

    assert subscription.rejected?
    assert_no_streams
  end

  test 'rejects a legacy nil-subject notification without streaming nil' do
    notification = create(:notification, user: @user)
    subscribe notification: notification.id

    assert subscription.rejected?
    assert_no_streams
  end

  test 'preserves visible owned Issue subscriptions' do
    notification = create(:notification, user: @user)
    subject = create(:subject, notifications: [notification])

    subscribe notification: notification.id

    assert subscription.confirmed?
    assert_has_stream "comments:#{subject.id}"
  end

  test 'preserves visible owned PullRequest subscriptions' do
    notification = create(:notification, user: @user, subject_type: 'PullRequest')
    subject = create(:subject, notifications: [notification])

    subscribe notification: notification.id

    assert subscription.confirmed?
    assert_has_stream "comments:#{subject.id}"
  end
end
