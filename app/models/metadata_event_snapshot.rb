# frozen_string_literal: true

class MetadataEventSnapshot < ApplicationRecord
  FRESH_FOR = 5.minutes
  STATUSES = %w[stale refreshing complete incomplete].freeze

  belongs_to :subject
  belongs_to :viewer, class_name: 'User', optional: true
  has_many :metadata_events, dependent: :delete_all

  validates :scope_key, presence: true, uniqueness: { scope: :subject_id }
  validates :status, inclusion: { in: STATUSES }
  validates :generation, :total_count,
            numericality: { only_integer: true, greater_than_or_equal_to: 0 }

  scope :publicly_visible, -> { where(scope_key: 'public', viewer_id: nil) }

  def self.for_presentation(subject, viewer)
    if subject.repository&.private?
      return unless viewer&.effective_access_token.present?
      return unless subject.notifications.exists?(user_id: viewer.id)

      find_by(subject: subject, scope_key: "viewer:#{viewer.id}", viewer: viewer)
    else
      find_by(subject: subject, scope_key: 'public', viewer: nil)
    end
  end

  def self.purge_public_for_subject_url(subject_url)
    Subject.find_by(url: subject_url)&.metadata_event_snapshots&.publicly_visible&.destroy_all
  end

  def self.purge_public_for_repository(repository_full_name)
    joins(:subject).publicly_visible
      .where(subjects: { repository_full_name: repository_full_name })
      .destroy_all
  end

  def fresh?
    status == 'complete' && refreshed_at.present? && refreshed_at >= FRESH_FOR.ago
  end

  def stale_data?
    metadata_events.exists? && status != 'complete'
  end
end
