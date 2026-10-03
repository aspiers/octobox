# frozen_string_literal: true

class LifecycleEvent < ApplicationRecord
  EVENT_TYPES = %w[
    closed
    reopened
    merged
    convert_to_draft
    ready_for_review
    committed
    head_ref_deleted
    head_ref_restored
    head_ref_force_pushed
    base_ref_force_pushed
    base_ref_changed
  ].freeze
  STATE_REASON_LIMIT = 64

  belongs_to :lifecycle_event_snapshot

  validates :github_identity, :event_type, :occurred_at, presence: true
  validates :event_type, inclusion: { in: EVENT_TYPES }
  validates :github_identity, uniqueness: { scope: :lifecycle_event_snapshot_id }

  scope :chronological, -> { order(:occurred_at, :github_identity) }

  def self.latest_chronologically(limit = 50)
    order(occurred_at: :desc, github_identity: :desc).limit(limit).to_a.reverse
  end

  def state_reason_label
    state_reason&.tr('_', ' ')
  end

  def short_commit_sha
    commit_sha&.first(7)
  end

  def short_before_commit_sha
    before_commit_sha&.first(7)
  end

  def short_after_commit_sha
    after_commit_sha&.first(7)
  end
end
