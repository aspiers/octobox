require 'test_helper'

class NotificationUndoActionTest < ActiveSupport::TestCase
  test 'record_archive stores previous archived states' do
    user = create(:user)
    notification1 = create(:notification, user: user, archived: false)
    notification2 = create(:notification, user: user, archived: true)

    undo_action = NotificationUndoAction.record_archive!(user, user.notifications.where(id: [notification1.id, notification2.id]))

    states = undo_action.notification_states.index_by { |state| state['id'] }
    assert_equal false, states[notification1.id]['archived']
    assert_equal true, states[notification2.id]['archived']
    assert undo_action.expires_at.future?
  end

  test 'record_archive stores the action type' do
    user = create(:user)
    create(:notification, user: user)

    assert_equal 'archive', NotificationUndoAction.record_archive!(user, user.notifications).action
    assert_equal 'unarchive', NotificationUndoAction.record_archive!(user, user.notifications, archived: false).action
  end

  test 'record_archive only deletes expired undo actions for the same user' do
    user = create(:user)
    other_user = create(:user)
    notification = create(:notification, user: user)
    create(:notification, user: other_user)
    expired_action = NotificationUndoAction.record_archive!(user, user.notifications.where(id: notification.id), archived: false)
    other_expired_action = NotificationUndoAction.record_archive!(other_user, other_user.notifications, archived: false)
    expired_action.update!(expires_at: 1.minute.ago)
    other_expired_action.update!(expires_at: 1.minute.ago)

    NotificationUndoAction.record_archive!(user, user.notifications.where(id: notification.id))

    refute NotificationUndoAction.exists?(expired_action.id)
    assert NotificationUndoAction.exists?(other_expired_action.id)
  end

  test 'record_archive keeps expired archive actions until their GitHub archive runs' do
    user = create(:user)
    notification = create(:notification, user: user)
    expired_action = NotificationUndoAction.record_archive!(user, user.notifications.where(id: notification.id))
    expired_action.update!(expires_at: 1.minute.ago)

    NotificationUndoAction.record_archive!(user, user.notifications.where(id: notification.id))

    assert NotificationUndoAction.exists?(expired_action.id)
  end

  test 'restore reverts archived states and destroys the undo action' do
    user = create(:user)
    notification1 = create(:notification, user: user, archived: false)
    notification2 = create(:notification, user: user, archived: true)
    undo_action = NotificationUndoAction.record_archive!(user, user.notifications.where(id: [notification1.id, notification2.id]))

    notification1.update!(archived: true)
    notification2.update!(archived: false)

    assert undo_action.restore!
    refute notification1.reload.archived?
    assert notification2.reload.archived?
    refute NotificationUndoAction.exists?(undo_action.id)
  end

  test 'restore does not revert expired undo action' do
    user = create(:user)
    notification = create(:notification, user: user, archived: false)
    undo_action = NotificationUndoAction.record_archive!(user, user.notifications.where(id: notification.id))
    undo_action.update!(expires_at: 1.minute.ago)
    notification.update!(archived: true)

    refute undo_action.restore!
    assert notification.reload.archived?
    assert NotificationUndoAction.exists?(undo_action.id)
  end

  test 'record keeps expired mute actions until their GitHub mute runs' do
    user = create(:user)
    notification = create(:notification, user: user)
    expired_action = NotificationUndoAction.record!(user, user.notifications, 'mute')
    expired_delete = NotificationUndoAction.record!(user, user.notifications, 'delete')
    expired_action.update!(expires_at: 1.minute.ago)
    expired_delete.update!(expires_at: 1.minute.ago)

    NotificationUndoAction.record!(user, user.notifications.where(id: notification.id), 'archive')

    assert NotificationUndoAction.exists?(expired_action.id)
    refute NotificationUndoAction.exists?(expired_delete.id)
  end

  test 'restore reverts a mute' do
    user = create(:user)
    notification = create(:notification, user: user, archived: false, unread: true)
    notifications = user.notifications.where(id: notification.id)
    undo_action = NotificationUndoAction.record!(user, notifications, 'mute')
    Notification.mute(notifications, undo_action: undo_action)
    assert notification.reload.muted_at

    assert undo_action.restore!

    notification.reload
    assert_nil notification.muted_at
    refute notification.archived?
    assert notification.unread?
  end

  test 'restore recreates deleted notifications' do
    user = create(:user)
    notification = create(:notification, user: user, starred: true, subject_title: 'Deleted one')
    notifications = user.notifications.where(id: notification.id)
    undo_action = NotificationUndoAction.record!(user, notifications, 'delete')
    notifications.delete_all

    assert undo_action.restore!

    restored = user.notifications.find(notification.id)
    assert_equal notification.github_id, restored.github_id
    assert_equal 'Deleted one', restored.subject_title
    assert restored.starred?
    assert_in_delta notification.updated_at, restored.updated_at, 0.001
  end

  test 'restore keeps a deleted notification that sync brought back' do
    user = create(:user)
    notification = create(:notification, user: user, subject_title: 'Old title')
    notifications = user.notifications.where(id: notification.id)
    undo_action = NotificationUndoAction.record!(user, notifications, 'delete')
    notifications.delete_all
    resynced = create(:notification, user: user, github_id: notification.github_id, subject_title: 'New title')

    assert undo_action.restore!

    assert_equal [resynced.id], user.notifications.where(github_id: notification.github_id).pluck(:id)
    assert_equal 'New title', resynced.reload.subject_title
  end
end
