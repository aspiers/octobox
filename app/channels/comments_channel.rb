class CommentsChannel < ApplicationCable::Channel

  def subscribed
    notification = current_user&.notifications&.find_by(id: params[:notification])
    return reject unless notification&.display_thread? && notification.display?

    stream_for notification.subject
  end

  def unsubscribed
    stop_all_streams
  end
end
