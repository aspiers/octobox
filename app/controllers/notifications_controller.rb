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
    @ci_activities = ci_activities_for(@notification)
    load_reference_activities(@notification)

    load_lifecycle_events
    comment_count = @notification.subject&.comment_count.to_i
    conversation_limit = comment_count <= COMMENTS_AUTOLOAD_LIMIT ? nil : DEFAULT_COMMENTS_LIMIT
    @conversation_page = conversation_page(@notification, limit: conversation_limit)
    @comments_left_to_load = @conversation_page.remaining_count

    render partial: "notifications/thread", layout: false if request.xhr?
  end

  def expand_comments
    scope = load_and_count_notifications(notifications_for_presentation.newest)

    load_notification_navigation(scope)
    @ci_activities = ci_activities_for(@notification)
    load_reference_activities(@notification)

    load_lifecycle_events
    @comments_left_to_load = 0
    @conversation_page = conversation_page(@notification)

    render 'notifications/show'
  end

  def conversation_page(notification, limit: nil)
    if notification.display? && notification.subject
      NotificationConversationPresenter.new(notification.subject, lifecycle_events: @lifecycle_events).page(limit: limit)
    else
      NotificationConversationPresenter::Page.new(entries: [], remaining_count: 0, total_count: 0)
    end
  end

  private :conversation_page

  def comment
    subject = current_user.notifications.find(params[:id]).subject

    if current_user.can_comment?(subject)
      comment = subject.comment(current_user, params[:comment][:body]) if subject.commentable?
      if request.xhr?
        if comment&.persisted?
          render partial: "notifications/issue_comment", locals: {comment: comment}, layout: false
        else
          head :unprocessable_entity
        end
      else
        redirect_back fallback_location: notification_path
      end
    else
      flash[:error] = 'Could not post your comment'
      if request.xhr?
        head :forbidden
      else
        redirect_back fallback_location: notification_path
      end
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

  def load_lifecycle_events
    @lifecycle_events = []
    return unless @notification.subject&.issue_or_pull_request? && @notification.display?

    subject = @notification.subject
    @lifecycle_event_snapshot = LifecycleEventSnapshot.for_presentation(subject, current_user)
    unless @lifecycle_event_snapshot&.fresh?
      viewer_id = subject.repository&.private? ? current_user.id : nil
      RefreshLifecycleEventsWorker.perform_async_if_configured(subject.id, viewer_id)
    end
    return unless @lifecycle_event_snapshot

    @lifecycle_events = @lifecycle_event_snapshot.lifecycle_events.to_a
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


  def load_reference_activities(notification)
    @reference_activities = []
    @reference_activity_count = 0
    return unless notification.display? && notification.subject
    return if notification.private?

    scope = notification.subject.reference_activities
    @reference_activity_count = scope.count
    @reference_activities = scope.recent_first.limit(50).to_a.reverse
  end
end
