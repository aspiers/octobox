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
    scope = load_and_count_notifications(scope) unless request.xhr?

    load_notification_navigation(scope)
    @ci_activities = ci_activities_for(@notification)

    @conversation_page = conversation_page(@notification, limit: 5)
    @comments_left_to_load = @conversation_page.remaining_count

    render partial: "notifications/thread", layout: false if request.xhr?
  end

  def expand_comments
    scope = load_and_count_notifications(notifications_for_presentation.newest)

    load_notification_navigation(scope)
    @ci_activities = ci_activities_for(@notification)

    @comments_left_to_load = 0
    @conversation_page = conversation_page(@notification)

    render 'notifications/show'
  end

  def conversation_page(notification, limit: nil)
    if notification.display? && notification.subject&.commentable?
      NotificationConversationPresenter.new(notification.subject).page(limit: limit)
    else
      NotificationConversationPresenter::Page.new(entries: [], remaining_count: 0, total_count: 0)
    end
  end

  private :conversation_page

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

  def ci_activities_for(notification)
    return CiActivity.none unless notification.display? && notification.subject&.pull_request?
    return CiActivity.none if notification.private?

    notification.subject.ci_activities.recent_first.limit(50)
  end
end
