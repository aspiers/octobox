# frozen_string_literal: true

class RefreshDeploymentActivityForCommitWorker
  include Sidekiq::Worker
  sidekiq_options queue: :sync_subjects, lock: :until_and_while_executing

  def perform(repository_full_name, sha)
    return if repository_full_name.blank? || sha.blank?

    DeploymentActivitySnapshot.refresh_for_commit(repository_full_name, sha)
  end
end
