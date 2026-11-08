require 'test_helper'

class MuteNotificationsWorkerTest < ActiveSupport::TestCase
  test 'mutes on GitHub without an undo action' do
    user = create(:user)

    Notification.expects(:mute_on_github).with(user, [123]).once

    MuteNotificationsWorker.new.perform(user.id, [123])
  end

  test 'skips GitHub mute when the undo action was consumed' do
    user = create(:user)

    Notification.expects(:mute_on_github).never

    MuteNotificationsWorker.new.perform(user.id, [123], 12345)
  end

  test 'reschedules GitHub mute while the undo action is still active' do
    user = create(:user)
    notification = create(:notification, user: user)
    undo_action = NotificationUndoAction.record!(user, user.notifications, 'mute')

    Notification.expects(:mute_on_github).never

    MuteNotificationsWorker.new.perform(user.id, [notification.github_id], undo_action.id)

    assert NotificationUndoAction.exists?(undo_action.id)
    assert_equal [user.id, [notification.github_id], undo_action.id], MuteNotificationsWorker.jobs.first['args']
  end

  test 'mutes on GitHub after the undo action expires' do
    user = create(:user)
    notification = create(:notification, user: user)
    undo_action = NotificationUndoAction.record!(user, user.notifications, 'mute')
    undo_action.update!(expires_at: 1.minute.ago)

    Notification.expects(:mute_on_github).with(user, [notification.github_id]).once

    MuteNotificationsWorker.new.perform(user.id, [notification.github_id], undo_action.id)

    refute NotificationUndoAction.exists?(undo_action.id)
  end
end
