# frozen_string_literal: true

class SyncReferenceActivitiesWorker
  include Sidekiq::Worker
  sidekiq_options queue: :sync_subjects, lock: :until_and_while_executing

  def perform(subject_id)
    Subject.find_by(id: subject_id)&.update_reference_activities
  end
end
