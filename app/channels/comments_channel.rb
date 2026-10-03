class CommentsChannel < ApplicationCable::Channel

  def subscribed
    return reject if current_user.nil?

    notification = current_user.notifications.find_by(id: params[:notification])
    return reject unless notification && !notification.ci_workflow_preview? && notification.display?
    return reject unless notification.display_thread?

    subject = notification.subject
    return reject unless subject

    stream_for subject
  end

  def unsubscribed
    stop_all_streams
  end
end
