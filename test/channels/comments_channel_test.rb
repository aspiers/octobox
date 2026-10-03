# frozen_string_literal: true

require "test_helper"

class CommentsChannelTest < ActionCable::Channel::TestCase
  setup do
    stub_include_comments
  end

  test "Reject subscriptions without a current user" do
    stub_connection current_user: nil
    subscribe

    assert subscription.rejected?
    assert_no_streams
  end

  test "rejects subscriptions for an unowned notification even when its subject is shared" do
    user = create(:user)
    other_user = create(:user)
    subject = create(:subject)
    create(:notification, user: user, subject_url: subject.url)
    other_notification = create(:notification, user: other_user, subject_url: subject.url)

    stub_connection(current_user: user)
    subscribe notification: other_notification.id

    assert subscription.rejected?
    assert_no_streams
  end

  test "rejects subscriptions when thread display is disabled" do
    user = create(:user)
    notification = create(:notification, user: user)
    create(:subject, notifications: [notification])
    Notification.any_instance.stubs(:display_thread?).returns(false)

    stub_connection(current_user: user)
    subscribe notification: notification.id

    assert subscription.rejected?
    assert_no_streams
  end

  test "rejects subscriptions when private content display is denied" do
    user = create(:user)
    other_user = create(:user)
    notification = create(:notification, user: user)
    subject = create(:subject, notifications: [notification])
    create(:notification, user: other_user, subject_url: subject.url)
    Notification.any_instance.stubs(:display_thread?).returns(true)
    Notification.any_instance.stubs(:display?).returns(false)

    stub_connection(current_user: user)
    subscribe notification: notification.id

    assert subscription.rejected?
    assert_no_streams
  end

  test "receives comment webhooks when created" do

    user = create(:user)
    notification = create(:notification, user: user)
    subject = create(:subject, notifications: [notification])
    Notification.any_instance.stubs(:display_thread?).returns(true)
    Notification.any_instance.stubs(:display?).returns(true)

    stub_connection(current_user: user)
    subscribe notification: notification.id

    assert_has_stream "comments:#{subject.id}"

    assert_broadcasts(subject, 1) do
      create(:comment, subject: subject)
    end

  end

  test "receives comment webhooks when updated" do

    user = create(:user)
    notification = create(:notification, user: user)
    subject = create(:subject, notifications: [notification])
    comment = create(:comment, subject: subject)
    Notification.any_instance.stubs(:display_thread?).returns(true)
    Notification.any_instance.stubs(:display?).returns(true)

    stub_connection(current_user: user)
    subscribe notification: notification.id

    assert_has_stream "comments:#{subject.id}"

    assert_broadcasts(subject, 1) do
      comment.update(body: "A new body")
    end

  end

end