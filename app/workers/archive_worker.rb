class ArchiveWorker
  include Sidekiq::Worker
  include UndoableGithubSync
  sidekiq_options queue: :user, lock: :until_and_while_executing

  def perform(user_id, notification_ids, undo_action_id = nil)
    user = User.find_by_id(user_id)
    return unless user

    after_undo_window(user, notification_ids, undo_action_id) do |undo_action|
      github_ids = undo_action ? undo_action.github_ids_to_archive(notification_ids) : notification_ids
      Notification.archive_on_github(user, github_ids) if github_ids.any?
    end
  end
end
