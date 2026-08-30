class NotificationUndoCleanupWorker
  include Sidekiq::Worker
  sidekiq_options queue: :user, lock: :until_executed

  def perform
    NotificationUndoAction.where(created_at: ...1.day.ago).delete_all
  end
end
