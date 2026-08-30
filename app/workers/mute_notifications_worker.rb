class MuteNotificationsWorker
  include Sidekiq::Worker
  sidekiq_options queue: :user, lock: :until_and_while_executing

  def perform(user_id, notification_ids, undo_action_id = nil)
    user = User.find_by_id(user_id)
    return unless user

    undo_action = NotificationUndoAction.find_by(id: undo_action_id) if undo_action_id
    return Notification.mute_on_github(user, notification_ids) unless undo_action_id
    return unless undo_action

    undo_action.with_lock do
      Notification.mute_on_github(user, notification_ids) if undo_action.persisted?
    end
  end
end
