# frozen_string_literal: true

class MetadataEvent < ApplicationRecord
  EVENT_TYPES = %w[
    renamed
    labeled
    unlabeled
    assigned
    unassigned
    milestoned
    demilestoned
    locked
    unlocked
    transferred
    connected
    disconnected
  ].freeze

  belongs_to :metadata_event_snapshot

  validates :github_identity, :event_type, :occurred_at, presence: true
  validates :event_type, inclusion: { in: EVENT_TYPES }
  validates :github_identity, uniqueness: { scope: :metadata_event_snapshot_id }

  scope :chronological, -> { order(:occurred_at, :github_identity) }

  def self.latest_chronologically(limit = 50)
    order(occurred_at: :desc, github_identity: :desc).limit(limit).to_a.reverse
  end
end
