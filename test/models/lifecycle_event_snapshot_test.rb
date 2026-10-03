# frozen_string_literal: true

require 'test_helper'

class LifecycleEventSnapshotTest < ActiveSupport::TestCase
  test 'private snapshots are returned only to their viewer' do
    repository = create(:repository, private: true)
    subject = create(:subject, repository: repository)
    viewer = create(:user)
    other_user = create(:user)
    create(:notification, user: viewer, subject_url: subject.url, repository_full_name: repository.full_name)
    snapshot = create(
      :lifecycle_event_snapshot,
      subject: subject,
      viewer: viewer,
      scope_key: "viewer:#{viewer.id}"
    )

    assert_equal snapshot, LifecycleEventSnapshot.for_presentation(subject, viewer)
    assert_nil LifecycleEventSnapshot.for_presentation(subject, other_user)
  end

  test 'public purge removes only public snapshots for a repository' do
    repository = create(:repository)
    subject = create(:subject, repository: repository)
    viewer = create(:user)
    public_snapshot = create(:lifecycle_event_snapshot, subject: subject)
    private_snapshot = create(
      :lifecycle_event_snapshot,
      subject: subject,
      viewer: viewer,
      scope_key: "viewer:#{viewer.id}"
    )

    LifecycleEventSnapshot.purge_public_for_repository(repository.full_name)

    refute LifecycleEventSnapshot.exists?(public_snapshot.id)
    assert LifecycleEventSnapshot.exists?(private_snapshot.id)
  end
end
