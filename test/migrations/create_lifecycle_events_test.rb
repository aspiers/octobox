# frozen_string_literal: true

require 'test_helper'
require Rails.root.join('db/migrate/20260831000000_create_lifecycle_events')

class CreateLifecycleEventsTest < ActiveSupport::TestCase
  test 'uses Rails 7.1 migration compatibility' do
    assert_equal ActiveRecord::Migration[7.1], CreateLifecycleEvents.superclass
  end

  test 'creates only the lifecycle snapshot and event tables' do
    schema = Rails.root.join('db/schema.rb').read
    lifecycle_tables = schema.scan(/create_table "(lifecycle[^\"]+)"/).flatten

    assert_equal %w[lifecycle_event_snapshots lifecycle_events], lifecycle_tables
  end

  test 'adds the snapshot identity and chronology indexes' do
    event_indexes = ActiveRecord::Base.connection.indexes(:lifecycle_events)

    assert event_indexes.any? { |index| index.name == 'index_lifecycle_events_on_snapshot_and_identity' && index.unique }
    assert event_indexes.any? { |index| index.name == 'index_lifecycle_events_on_snapshot_and_time' }
  end

  test 'cascades lifecycle records when their subject is deleted' do
    subject = create(:subject)
    snapshot = create(:lifecycle_event_snapshot, subject: subject)
    event = create(:lifecycle_event, lifecycle_event_snapshot: snapshot)

    subject.delete

    refute LifecycleEventSnapshot.exists?(snapshot.id)
    refute LifecycleEvent.exists?(event.id)
  end
end
