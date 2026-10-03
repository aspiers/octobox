# frozen_string_literal: true

class SyncSubjectWorker
  include Sidekiq::Worker
  sidekiq_options queue: :sync_subjects, lock: :until_and_while_executing

  # Extras travel in one options hash so that features adding their own keys
  # share a single job signature.
  def perform(remote_subject, options = {})
    subject = Subject.sync(remote_subject)
    remote_comment = options['comment'] || options[:comment]
    return unless remote_comment && Octobox.include_comments?

    subject.sync_issue_comment_event(
      remote_comment,
      action: options['action'] || options[:action],
      repository_github_id: options['repository_id'] || options[:repository_id]
    )
  end
end
