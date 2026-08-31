# frozen_string_literal: true

require 'test_helper'
require Rails.root.join('db/migrate/20260831010000_create_metadata_events')

class CreateMetadataEventsTest < ActiveSupport::TestCase
  test 'uses Rails 7.1 migration compatibility' do
    assert_equal ActiveRecord::Migration[7.1], CreateMetadataEvents.superclass
  end

  test 'adds only this branch metadata tables to the base schema' do
    schema = Rails.root.join('db/schema.rb').read
    activity_tables = schema.scan(/create_table "((?:metadata|lifecycle|reference|review|ci)[^"]+)"/).flatten

    assert_equal %w[metadata_event_snapshots metadata_events], activity_tables
  end

  test 'adds stable identity and chronology indexes' do
    indexes = ActiveRecord::Base.connection.indexes(:metadata_events)

    assert indexes.any? { |index| index.name == 'index_metadata_events_on_snapshot_and_identity' && index.unique }
    assert indexes.any? { |index| index.name == 'index_metadata_events_on_snapshot_and_time' }
  end

  test 'cascades snapshots and events when a subject is deleted' do
    subject = create(:subject)
    snapshot = create(:metadata_event_snapshot, subject: subject)
    event = create(:metadata_event, metadata_event_snapshot: snapshot)

    subject.delete

    refute MetadataEventSnapshot.exists?(snapshot.id)
    refute MetadataEvent.exists?(event.id)
  end
end
