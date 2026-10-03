# frozen_string_literal: true

# CheckSuite notifications have no synced Subject or exact run URL. Only describe
# what this notification reports, leaving unfamiliar titles intact.
class CiWorkflowPreview
  STATUSES = {
    'failed' => 'Failed',
    'succeeded' => 'Succeeded',
    'cancelled' => 'Cancelled',
    'canceled' => 'Cancelled',
    'pending' => 'Pending',
    'queued' => 'Queued',
    'in progress' => 'In progress',
    'completed' => 'Completed'
  }.freeze
  TITLE_PATTERN = /\A(?<workflow>.+) workflow run(?:, Attempt #(?<attempt>[1-9]\d*))? (?<status>#{Regexp.union(STATUSES.keys)}) for (?<branch>.+) branch\z/

  attr_reader :title, :workflow, :status, :attempt, :branch

  def initialize(title)
    @title = title
    match = TITLE_PATTERN.match(title.to_s)
    return unless match

    @workflow = match[:workflow]
    @status = STATUSES.fetch(match[:status])
    @attempt = match[:attempt]
    @branch = match[:branch]
  end
end
