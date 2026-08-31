# frozen_string_literal: true

require "uri"

class CiActivity < ApplicationRecord
  KINDS = %w[status check_run check_suite].freeze
  FAILURE_OUTCOMES = %w[error failure stale startup_failure timed_out].freeze
  OUTCOMES = %w[pending success failure cancelled skipped neutral action_required].freeze

  belongs_to :subject

  validates :kind, inclusion: { in: KINDS }
  validates :github_id, :head_sha, :name, presence: true
  validates :github_id, uniqueness: { scope: [:subject_id, :kind] }

  scope :recent_first, lambda {
    order(
      Arel.sql("COALESCE(completed_at, github_updated_at, started_at, github_created_at, created_at) DESC"),
      id: :desc
    )
  }

  def outcome
    raw_outcome = conclusion.presence || (state if kind == "status")
    return "pending" if raw_outcome.blank? || %w[queued in_progress requested waiting pending].include?(raw_outcome)
    return "failure" if FAILURE_OUTCOMES.include?(raw_outcome)

    OUTCOMES.include?(raw_outcome) ? raw_outcome : "neutral"
  end

  def outcome_label
    raw_outcome = conclusion.presence || (state if kind == "status")
    return "Pending" if raw_outcome.blank? || %w[queued in_progress requested waiting pending].include?(raw_outcome)

    raw_outcome.humanize
  end

  def event_at
    completed_at || github_updated_at || started_at || github_created_at || created_at
  end

  def safe_target_url
    uri = URI.parse(target_url.to_s)
    return unless uri.is_a?(URI::HTTP) && uri.host.present? && uri.userinfo.nil?

    uri.to_s
  rescue URI::InvalidURIError
    nil
  end
end
