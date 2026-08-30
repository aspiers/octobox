# frozen_string_literal: true

class NotificationUndoAction < ApplicationRecord
  SNAPSHOT_VERSION = 1
  DELETE_FIELDS = %w[
    id user_id github_id repository_id repository_full_name subject_title
    subject_url subject_type reason unread last_read_at url archived created_at
    updated_at starred repository_owner_name latest_comment_url muted_at
  ].freeze
  ACTION_FIELDS = {
    'archive' => %w[id archived],
    'mute' => %w[id github_id archived unread muted_at],
    'delete' => DELETE_FIELDS
  }.freeze

  belongs_to :user

  validates :token, presence: true, uniqueness: true
  validates :action_type, inclusion: { in: ACTION_FIELDS.keys }
  validates :snapshot_version, inclusion: { in: [SNAPSHOT_VERSION] }

  def self.capture!(user:, action_type:, notifications:)
    records = notifications.to_a
    return if records.empty?

    fields = ACTION_FIELDS.fetch(action_type.to_s)
    states = records.map { |notification| notification.attributes.slice(*fields) }
    where(created_at: ...1.day.ago).delete_all
    action = create!(
      user: user,
      action_type: action_type,
      token: SecureRandom.hex(24),
      snapshot_version: SNAPSHOT_VERSION,
      states: states
    )
    action
  end

  def notification_ids
    states.map { |state| state.fetch('id') }
  end

  def undo!
    unless snapshot_version == SNAPSHOT_VERSION
      raise ActiveRecord::RecordNotFound, 'Unsupported undo snapshot version'
    end

    expired = false
    with_lock do
      if created_at < 1.day.ago
        destroy!
        expired = true
      else
        action_type == 'delete' ? restore_deleted_notifications : restore_notification_state
        destroy!
      end
    end
    raise ActiveRecord::RecordNotFound, 'Undo action has expired' if expired

    compensate_remote_action
  end

  private

  def compensate_remote_action
    return unless action_type == 'mute'

    github_ids = states.filter_map do |state|
      state['github_id'] if state['muted_at'].blank?
    end
    UnmuteNotificationsWorker.perform_async_if_configured(user.id, github_ids) if github_ids.any?
  end

  def restore_deleted_notifications
    states.each do |attributes|
      attributes = attributes.slice(*Notification.column_names)
      existing = user.notifications.find_by(id: attributes.fetch('id'))
      github_id = attributes['github_id']
      existing ||= user.notifications.find_by(github_id: github_id) if github_id.present?

      if existing
        existing.update_columns(attributes)
      else
        Notification.create!(attributes)
      end
    end
  end

  def restore_notification_state
    states.each do |state|
      notification = user.notifications.find_by(id: state.fetch('id'))
      notification&.update_columns(state.except('id'))
    end
  end
end
