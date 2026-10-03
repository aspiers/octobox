# frozen_string_literal: true

require 'test_helper'

class NotificationUndoWorkersTest < ActiveSupport::TestCase
  setup do
    @user = create(:user)
    @notification = create(:notification, user: @user)
  end

  test 'archive worker skips remote work after undo action is consumed' do
    action = capture(:archive)
    action.destroy!
    Notification.expects(:archive_on_github).never

    ArchiveWorker.new.perform(@user.id, [@notification.github_id], action.id)
  end

  test 'mute worker serializes remote work through the undo action' do
    action = capture(:mute)
    Notification.expects(:mute_on_github).with(@user, [@notification.github_id])

    MuteNotificationsWorker.new.perform(@user.id, [@notification.github_id], action.id)
  end

  test 'cleanup worker removes expired undo actions' do
    action = capture(:delete)
    action.update_column(:created_at, 2.days.ago)

    NotificationUndoCleanupWorker.new.perform

    refute NotificationUndoAction.exists?(action.id)
  end

  test 'cleanup worker preserves current undo actions' do
    action = capture(:delete)

    NotificationUndoCleanupWorker.new.perform

    assert NotificationUndoAction.exists?(action.id)
  end

  private

  def capture(action_type)
    NotificationUndoAction.capture!(
      user: @user,
      action_type: action_type,
      notifications: Notification.where(id: @notification.id)
    )
  end
end
