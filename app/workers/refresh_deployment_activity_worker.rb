# frozen_string_literal: true

class RefreshDeploymentActivityWorker
  include Sidekiq::Worker
  sidekiq_options queue: :sync_subjects, retry: 5, lock: :until_and_while_executing

  def perform(snapshot_id, generation)
    snapshot = DeploymentActivitySnapshot.find_by(id: snapshot_id)
    return unless snapshot && snapshot.generation == generation

    client = snapshot.authorized_client
    raise DeploymentActivityFetcher::AuthorizationError, 'No authorized GitHub client for deployment activity' unless client

    result = DeploymentActivityFetcher.new(subject: snapshot.subject, client: client).call
    snapshot.apply_result!(result, generation)
  rescue StandardError
    snapshot&.record_failure!(generation)
    raise
  end
end
