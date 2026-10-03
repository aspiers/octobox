# frozen_string_literal: true

require 'test_helper'

class NotificationUndoActionTest < ActiveSupport::TestCase
  setup do
    @user = create(:user)
  end

  test 'undo restores archived state' do
    notification = create(:notification, user: @user, archived: false)
    action = NotificationUndoAction.capture!(
      user: @user,
      action_type: :archive,
      notifications: Notification.where(id: notification.id)
    )
    notification.update!(archived: true)

    action.undo!

    refute notification.reload.archived?
    refute NotificationUndoAction.exists?(action.id)
  end

  test 'undo restores state changed by muting' do
    notification = create(:notification, user: @user, archived: false, unread: true, muted_at: nil)
    UnmuteNotificationsWorker.expects(:perform_async_if_configured).with(@user.id, [notification.github_id])
    action = NotificationUndoAction.capture!(
      user: @user,
      action_type: :mute,
      notifications: Notification.where(id: notification.id)
    )
    notification.update!(archived: true, unread: false, muted_at: Time.current)

    action.undo!

    notification.reload
    refute notification.archived?
    assert notification.unread?
    assert_nil notification.muted_at
  end

  test 'undo does not remotely unmute a notification that was already muted' do
    notification = create(:notification, user: @user, muted_at: 1.day.ago)
    UnmuteNotificationsWorker.expects(:perform_async_if_configured).never
    action = NotificationUndoAction.capture!(
      user: @user,
      action_type: :mute,
      notifications: Notification.where(id: notification.id)
    )

    action.undo!

    assert notification.reload.muted_at?
  end

  test 'undo recreates deleted notifications' do
    notification = create(:notification, user: @user)
    attributes = notification.attributes
    action = NotificationUndoAction.capture!(
      user: @user,
      action_type: :delete,
      notifications: Notification.where(id: notification.id)
    )
    notification.delete

    action.undo!

    restored = Notification.find(notification.id)
    assert_equal attributes.except('created_at'), restored.attributes.except('created_at')
    assert_in_delta attributes.fetch('created_at').to_f, restored.created_at.to_f, 0.001
  end

  test 'delete undo reconciles a notification recreated by sync' do
    notification = create(:notification, user: @user)
    original_id = notification.id
    action = NotificationUndoAction.capture!(
      user: @user,
      action_type: :delete,
      notifications: Notification.where(id: original_id)
    )
    notification.delete
    replacement = create(:notification, user: @user, github_id: notification.github_id)
    replacement_id = replacement.id

    action.undo!

    assert Notification.exists?(original_id)
    refute Notification.exists?(replacement_id)
    assert_equal notification.github_id, Notification.find(original_id).github_id
  end

  test 'unsupported snapshot versions are rejected' do
    notification = create(:notification, user: @user)
    action = NotificationUndoAction.capture!(
      user: @user,
      action_type: :archive,
      notifications: Notification.where(id: notification.id)
    )
    action.update_column(:snapshot_version, 99)

    assert_raises(ActiveRecord::RecordNotFound) { action.undo! }
    assert NotificationUndoAction.exists?(action.id)
  end

  test 'expired undo actions are consumed and rejected' do
    notification = create(:notification, user: @user)
    action = NotificationUndoAction.capture!(
      user: @user,
      action_type: :archive,
      notifications: Notification.where(id: notification.id)
    )
    action.update_column(:created_at, 2.days.ago)

    assert_raises(ActiveRecord::RecordNotFound) { action.undo! }
    refute NotificationUndoAction.exists?(action.id)
  end

  test 'capture returns nil for an empty selection' do
    assert_nil NotificationUndoAction.capture!(
      user: @user,
      action_type: :archive,
      notifications: Notification.none
    )
  end
end
