# frozen_string_literal: true

class RefreshLifecycleEventsWorker
  include Sidekiq::Worker
  sidekiq_options queue: :sync_subjects

  def perform(subject_id, viewer_id = nil)
    subject = Subject.find_by(id: subject_id)
    return unless subject

    viewer = User.find_by(id: viewer_id) if viewer_id
    LifecycleEvents::Refresh.new(subject: subject, viewer: viewer).call
  end

  def self.schedule_for(subject, private_repository: subject.repository&.private?)
    if private_repository
      subject.lifecycle_event_snapshots.publicly_visible.destroy_all
      subject.users.with_github_token.find_each do |viewer|
        perform_async_if_configured(subject.id, viewer.id)
      end
    else
      subject.lifecycle_event_snapshots.where.not(viewer_id: nil).destroy_all
      perform_async_if_configured(subject.id)
    end
  end
end
