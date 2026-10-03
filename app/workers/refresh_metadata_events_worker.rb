# frozen_string_literal: true

class RefreshMetadataEventsWorker
  include Sidekiq::Worker
  sidekiq_options queue: :sync_subjects, lock: :until_and_while_executing

  def perform(subject_id, viewer_id = nil)
    subject = Subject.find_by(id: subject_id)
    return unless subject

    viewer = User.find_by(id: viewer_id) if viewer_id
    MetadataEvents::Refresh.new(subject: subject, viewer: viewer).call
  end

  def self.enqueue(subject, viewer = nil)
    return unless Octobox.background_jobs_enabled?

    perform_async_if_configured(subject.id, viewer&.id)
  end

  def self.schedule_for(subject, private_repository: subject.repository&.private?)
    if private_repository
      subject.metadata_event_snapshots.publicly_visible.destroy_all
      subject.users.with_github_token.find_each { |viewer| schedule(subject, viewer) }
    else
      subject.metadata_event_snapshots.where.not(viewer_id: nil).destroy_all
      schedule(subject)
    end
  end

  def self.schedule(subject, viewer = nil)
    if Octobox.background_jobs_enabled?
      enqueue(subject, viewer)
    else
      new.perform(subject.id, viewer&.id)
    end
  end
end
