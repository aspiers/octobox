# frozen_string_literal: true
class NotificationsController < ApplicationController
  include NotificationsConcern

  skip_before_action :authenticate_user!
  before_action :authenticate_web_or_api!
  before_action :find_notification, only: [:star]

  def index
    load_and_count_notifications
    respond_to do |format|
      format.html
      format.json { render 'api/notifications/index' }
    end
  end

  def show
    scope = notifications_for_presentation.newest
    if request.xhr?
      # Keep the opened notification as the anchor: its mark-read request may land first under ?unread=true
      scope = scope.where(id: current_notifications(scope)).or(scope.where(id: params[:id]))
    else
      scope = load_and_count_notifications(scope)
    end

    ids = scope.pluck(:id)
    position = ids.index(params[:id].to_i)
    @notification = current_user.notifications.find(params[:id])
    @previous = ids[position-1] unless position.nil? || position-1 < 0
    @next = ids[position+1] unless position.nil? || position+1 > ids.length

    if @notification.subject && @notification.subject.commentable?
      comments_loaded = 5
      @comments = @notification.subject.comments.order('created_at DESC').limit(comments_loaded).reverse
      @comments_left_to_load = @notification.subject.comment_count - comments_loaded
      @comments_left_to_load = 0 if @comments_left_to_load < 0
    else
      @comments = []
    end

    render partial: "notifications/thread", layout: false if request.xhr?
  end

  def expand_comments
    scope = notifications_for_presentation.newest
    scope = load_and_count_notifications(scope) unless request.xhr?

    ids = scope.pluck(:id)
    position = ids.index(params[:id].to_i)
    @notification = current_user.notifications.find(params[:id])
    @previous = ids[position-1] unless position.nil? || position-1 < 0
    @next = ids[position+1] unless position.nil? || position+1 > ids.length

    @comments_left_to_load = 0

    if @notification.subject
      @comments = @notification.subject.comments.order('created_at ASC')
    else
      @comments = []
    end

    if request.xhr?
      render partial: "notifications/comments", locals:{comments: @comments}, layout: false
    else
      render 'notifications/show'
    end
  end

  def comment
    subject = current_user.notifications.find(params[:id]).subject

    if current_user.can_comment?(subject)
      subject.comment(current_user, params[:comment][:body]) if subject.commentable?
      if request.xhr?
        render partial: "notifications/comments", locals:{comments: subject.comments.last}, layout: false
      else
        redirect_back fallback_location: notification_path
      end
    else
      flash[:error] = 'Could not post your comment'
      redirect_back fallback_location: notification_path
    end
  end

  def unread_count
    render json: { 'count' => user_unread_count }
  end

  def lookup
    if params[:url].present?
      url = Octobox::SubjectUrlParser.new(params[:url]).to_api_url
      @notification = current_user.notifications.where(subject_url: url).first
      if @notification.nil?
        render json: {}
      else
        render 'api/notifications/lookup'
      end
    else
      render json: {}
    end
  end

  def mute_selected
    notifications = selected_notifications
    undo_action = record_undo_action(notifications, 'mute')
    Notification.mute(notifications, undo_action: undo_action)
    respond_with_undo(undo_action)
  end

  def archive_selected
    notifications = selected_notifications
    undo_action = record_undo_action(notifications, archive_value ? 'archive' : 'unarchive')

    Notification.archive(notifications, params[:value], undo_action: undo_action)
    respond_with_undo(undo_action)
  end

  def undo_archive
    undo_action = current_user.notification_undo_actions.find_by(token: params[:token])
    undone = undo_action&.restore!
    return head(undone ? :ok : :not_found) if request.xhr?

    if undone
      flash[:success] = 'Notification action undone'
    else
      flash[:error] = 'Undo link has expired'
    end

    redirect_back fallback_location: root_path
  end

  def mark_read_selected
    Notification.mark_read(selected_notifications)
    head :ok
  end

  def delete_selected
    notifications = selected_notifications
    undo_action = record_undo_action(notifications, 'delete')
    notifications.delete_all
    respond_with_undo(undo_action)
  end

  def star
    @notification.update_columns starred: !@notification.starred?
    head :ok
  end

  def sync
    if Octobox.background_jobs_enabled?
      current_user.sync_notifications
    else
      current_user.sync_notifications_in_foreground
    end

    respond_to do |format|
      format.html do
        if request.referer && !request.referer.match('/notifications/sync')
          redirect_back fallback_location: root_path
        else
          redirect_to root_path
        end
      end
      format.json { {} }
    end
  end

  def syncing
    if current_user.syncing?
      render json: {}, status: :locked
    else
      render json: { error: Sidekiq::Status::get(current_user.sync_job_id, :exception) }, status: :ok
    end
  end

  private

  def respond_with_undo(undo_action)
    if request.xhr?
      render json: undo_payload(undo_action)
    else
      flash[:success] = undo_message(undo_action)
      redirect_back fallback_location: root_path
    end
  end

  def undo_payload(undo_action)
    return {} unless undo_action

    {
      message: 'Notification action complete.',
      undo_url: undo_archive_notifications_path(token: undo_action.token)
    }
  end

  def undo_message(undo_action)
    return 'Notification action complete.' unless undo_action

    undo_path = undo_archive_notifications_path(token: undo_action.token)
    "Notification action complete. <a href=\"#{undo_path}\" data-method=\"post\">Undo</a>"
  end

  def archive_value
    params[:value] ? ActiveRecord::Type::Boolean.new.cast(params[:value]) : true
  end

  # Without background jobs the GitHub sync runs at once, so it can't wait for undo
  def record_undo_action(notifications, action)
    return if NotificationUndoAction::SYNCED_ACTIONS.include?(action) && !Octobox.background_jobs_enabled?

    NotificationUndoAction.record!(current_user, notifications, action)
  end
end
