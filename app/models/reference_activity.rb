# frozen_string_literal: true

require "uri"

class ReferenceActivity < ApplicationRecord
  ACTIVITY_TYPES = %w[cross_reference mention commit_reference].freeze
  SOURCE_TYPES = %w[issue pull_request commit].freeze

  belongs_to :subject

  validates :stable_identity, :source_repository_full_name, :native_url, :occurred_at, presence: true
  validates :activity_type, inclusion: { in: ACTIVITY_TYPES }
  validates :source_type, inclusion: { in: SOURCE_TYPES }
  validates :stable_identity, uniqueness: { scope: :subject_id }

  scope :chronological, -> { order(occurred_at: :asc, id: :asc) }
  scope :recent_first, -> { order(occurred_at: :desc, id: :desc) }

  def safe_native_url
    uri = URI.parse(native_url.to_s)
    github_uri = URI.parse(Octobox.config.github_domain)
    return unless %w[http https].include?(uri.scheme)
    return unless uri.host == github_uri.host && uri.userinfo.nil?

    uri.to_s
  rescue URI::InvalidURIError
    nil
  end
end
