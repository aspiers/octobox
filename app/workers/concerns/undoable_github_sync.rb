# frozen_string_literal: true

# Holds a GitHub sync back until its undo window closes, and drops it if the
# user undid the action
module UndoableGithubSync
  def after_undo_window(user, notification_ids, undo_action_id)
    return yield(nil) unless undo_action_id

    undo_action = user.notification_undo_actions.find_by(id: undo_action_id)
    return unless undo_action

    unless undo_action.expired?
      self.class.perform_in(undo_action.archive_delay, user.id, notification_ids, undo_action_id)
      return
    end

    yield(undo_action)
    undo_action.destroy
  end
end
