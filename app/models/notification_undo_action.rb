# frozen_string_literal: true

class NotificationUndoAction < ApplicationRecord
  EXPIRES_IN = 5.minutes
  ARCHIVE_BUFFER = 10.seconds
  ARCHIVE_DELAY = EXPIRES_IN + ARCHIVE_BUFFER
  # Their GitHub sync waits for the undo window, so the record must outlive it
  SYNCED_ACTIONS = %w[archive mute].freeze
  RESTORED_FIELDS = {
    'archive' => %w[archived],
    'unarchive' => %w[archived],
    'mute' => %w[archived unread muted_at]
  }.freeze

  has_secure_token :token

  belongs_to :user

  validates :action, presence: true
  validates :expires_at, presence: true
  validates :notification_states, presence: true

  scope :expired, -> { where('expires_at <= ?', Time.current) }

  def self.record_archive!(user, notifications, archived: true)
    record!(user, notifications, archived ? 'archive' : 'unarchive')
  end

  def self.record!(user, notifications, action)
    states = notifications.map { |notification| state_for(notification, action) }

    return if states.empty?

    # Synced actions stay until their worker syncs them to GitHub, so a
    # missing record always means the user undid the action
    user.notification_undo_actions.expired.where.not(action: SYNCED_ACTIONS).delete_all

    user.notification_undo_actions.create!(
      action: action,
      notification_states: states,
      expires_at: EXPIRES_IN.from_now
    )
  end

  # Delete keeps every column so undo can recreate the row
  def self.state_for(notification, action)
    return notification.attributes.as_json if action == 'delete'

    notification.attributes.slice('id', *RESTORED_FIELDS.fetch(action)).as_json
      .merge('updated_at' => serialize_timestamp(notification.updated_at))
  end

  def self.serialize_timestamp(time)
    time&.utc&.iso8601(6)
  end

  def notification_states
    JSON.parse(read_attribute(:notification_states) || '[]')
  end

  def notification_states=(states)
    write_attribute(:notification_states, JSON.generate(states))
  end

  def expired?
    expires_at <= Time.current
  end

  def archive_delay
    [expires_at - Time.current, 0].max + ARCHIVE_BUFFER
  end

  # Notifications that sync reopened, or that received new activity, since
  # this archive was recorded must not be archived on GitHub
  def github_ids_to_archive(github_ids)
    recorded_updated_at = notification_states.to_h { |state| [state['id'], state['updated_at']] }

    reopened_github_ids = user.notifications.where(id: recorded_updated_at.keys)
      .pluck(:id, :github_id, :archived, :updated_at)
      .reject { |id, _, archived, updated_at| archived && recorded_updated_at[id] == self.class.serialize_timestamp(updated_at) }
      .map(&:second)

    github_ids - reopened_github_ids
  end

  def restore!
    return false if expired?

    transaction do
      action == 'delete' ? restore_deleted : restore_fields
      destroy!
    end

    true
  end

  private

  def restore_fields
    notification_states.group_by { |state| state.except('id', 'updated_at') }.each do |fields, states|
      user.notifications.where(id: states.map { |state| state['id'] }).update_all(fields)
    end
  end

  # A notification that sync brought back since the delete is newer, so keep it
  def restore_deleted
    states = notification_states
    resynced = user.notifications.where(github_id: states.map { |state| state['github_id'] }).pluck(:github_id)
    missing = states.reject { |state| resynced.include?(state['github_id']) }
    Notification.insert_all!(missing) if missing.any?
  end
end
