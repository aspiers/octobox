# frozen_string_literal: true
class NotificationsController < ApplicationController
  include NotificationsConcern

  COMMENTS_AUTOLOAD_LIMIT = 50
  DEFAULT_COMMENTS_LIMIT = 5

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
    scope = request.xhr? ? current_notifications(scope) : load_and_count_notifications(scope)

    load_notification_navigation(scope)

    if @notification.subject && @notification.subject.commentable?
      comment_count = @notification.subject.comment_count.to_i
      comments_loaded = comment_count <= COMMENTS_AUTOLOAD_LIMIT ? comment_count : DEFAULT_COMMENTS_LIMIT
      @comments = @notification.subject.comments.order('created_at DESC').limit(comments_loaded).reverse
      @comments_left_to_load = comment_count - comments_loaded
      @comments_left_to_load = 0 if @comments_left_to_load < 0
    else
      @comments = []
    end

    render partial: "notifications/thread", layout: false if request.xhr?
  end

  def expand_comments
    scope = load_and_count_notifications(notifications_for_presentation.newest)

    load_notification_navigation(scope)

    @comments_left_to_load = 0

    if @notification.subject
      @comments = @notification.subject.comments.order('created_at ASC')
    else
      @comments = []
    end

    render 'notifications/show'
  end

  def comment
    subject = current_user.notifications.find(params[:id]).subject

    if current_user.can_comment?(subject)
      subject.comment(current_user, params[:comment][:body]) if subject.commentable?
      redirect_back fallback_location: notification_path
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
    Notification.mute(selected_notifications)
    if request.xhr?
      head :ok
    else
      redirect_back fallback_location: root_path
    end
  end

  def archive_selected
    Notification.archive(selected_notifications, params[:value])
    if request.xhr?
      head :ok
    else
      redirect_back fallback_location: root_path
    end
  end

  def mark_read_selected
    Notification.mark_read(selected_notifications)
    head :ok
  end

  def delete_selected
    selected_notifications.delete_all
    if request.xhr?
      head :ok
    else
      redirect_back fallback_location: root_path
    end
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

  def load_notification_navigation(scope)
    ids = scope.pluck(:id)
    position = ids.index(params[:id].to_i)
    @notification = current_user.notifications.find(params[:id])
    @previous = ids[position-1] unless position.nil? || position-1 < 0
    @next = ids[position+1] unless position.nil? || position+1 > ids.length
  end
end
