# frozen_string_literal: true
require 'uri'

module CiWorkflowPreviewsHelper
  def ci_workflow_actions_url(notification)
    repository = notification.repository_full_name.to_s
    return unless repository.match?(/\A[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+\z/)
    return if repository.split('/').any? { |part| ['.', '..'].include?(part) }

    # Never use subject_url here: it may be an API URL or untrusted input.
    url = URI.parse(Octobox.config.github_domain)
    return unless %w[http https].include?(url.scheme) && url.host.present?
    return if url.userinfo || url.query || url.fragment

    url.path = "#{url.path.chomp('/')}/#{repository}/actions"
    url.to_s
  rescue URI::InvalidURIError
    nil
  end
end
