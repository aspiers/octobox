# frozen_string_literal: true

class RefreshRepositoryLifecycleEventsWorker
  include Sidekiq::Worker
  sidekiq_options queue: :sync_subjects

  def perform(repository_full_name, private_repository, active_only = false)
    subjects = Subject.where(repository_full_name: repository_full_name)
    subjects = subjects.where(state: 'open').where('url LIKE ?', '%/pulls/%') if active_only
    subjects.find_each do |subject|
      next unless subject.issue_or_pull_request?

      RefreshLifecycleEventsWorker.schedule_for(
        subject,
        private_repository: private_repository
      )
    end
  end
end
