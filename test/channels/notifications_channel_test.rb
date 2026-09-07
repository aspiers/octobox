# frozen_string_literal: true

require "test_helper"

class NotificationsChannelTest < ActionCable::Channel::TestCase


  test "Reject subscriptions without a current user" do
    stub_connection current_user: nil
    subscribe

    assert subscription.rejected?
    assert_no_streams
  end

  test "receives notification webhooks when updated" do
    user = create(:user)
    notification = create(:notification, user: user)

    stub_connection current_user: user
    subscribe
    assert_has_stream "notifications:#{user.id}"

    assert_broadcasts("notifications:#{user.id}", 1) do
      notification.update(archived: true)
    end
  end


  test "announces a newly created notification" do
    user = create(:user)

    stub_connection current_user: user
    subscribe
    assert_has_stream "notifications:#{user.id}"

    assert_broadcasts("notifications:#{user.id}", 1) do
      create(:notification, user: user)
    end
  end

  test "an arrival announcement carries no rendered row" do
    user = create(:user)
    stub_connection current_user: user
    subscribe

    create(:notification, user: user)

    payload = ActiveSupport::JSON.decode(broadcasts("notifications:#{user.id}").last)
    assert payload["arrived"], "arrival must be marked so the client can tell it apart"
    assert_nil payload["notification"],
               "the list is filtered and paginated server-side, so a row must not be pushed"
  end

end
