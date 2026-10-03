# frozen_string_literal: true

require 'test_helper'

class MetadataEventSnapshotTest < ActiveSupport::TestCase
  test 'presents public data to every viewer' do
    subject = create(:subject, repository: create(:repository, private: false))
    snapshot = create(:metadata_event_snapshot, subject: subject)

    assert_equal snapshot, MetadataEventSnapshot.for_presentation(subject, create(:user))
  end

  test 'presents private data only to its authorized viewer' do
    repository = create(:repository, private: true)
    subject = create(:subject, repository: repository)
    viewer = create(:user)
    other_viewer = create(:user)
    create(:notification, user: viewer, subject_url: subject.url,
                          repository_full_name: repository.full_name)
    snapshot = create(:metadata_event_snapshot, subject: subject, viewer: viewer,
                                                scope_key: "viewer:#{viewer.id}")

    assert_equal snapshot, MetadataEventSnapshot.for_presentation(subject, viewer)
    assert_nil MetadataEventSnapshot.for_presentation(subject, other_viewer)
  end

  test 'recognizes stale preserved data' do
    snapshot = create(:metadata_event_snapshot, status: 'incomplete')
    create(:metadata_event, metadata_event_snapshot: snapshot)

    assert snapshot.stale_data?
    refute snapshot.fresh?
  end
end
