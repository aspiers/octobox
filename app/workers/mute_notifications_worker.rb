class MuteNotificationsWorker
  include Sidekiq::Worker
  include UndoableGithubSync
  sidekiq_options queue: :user, lock: :until_and_while_executing

  def perform(user_id, notification_ids, undo_action_id = nil)
    user = User.find_by_id(user_id)
    return unless user

    after_undo_window(user, notification_ids, undo_action_id) do
      Notification.mute_on_github(user, notification_ids)
    end
  end
end
