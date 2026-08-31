# frozen_string_literal: true

require 'test_helper'

class MetadataEventTest < ActiveSupport::TestCase
  test 'accepts only metadata timeline event types' do
    event = build(:metadata_event)

    MetadataEvent::EVENT_TYPES.each do |event_type|
      event.event_type = event_type
      assert event.valid?, event.errors.full_messages.to_sentence
    end

    event.event_type = 'closed'
    refute event.valid?
  end

  test 'orders the latest events chronologically after applying the limit' do
    snapshot = create(:metadata_event_snapshot)
    55.times do |index|
      create(:metadata_event, metadata_event_snapshot: snapshot,
                              github_identity: "github:#{index}",
                              occurred_at: Time.utc(2026, 8, 1) + index.minutes)
    end

    events = snapshot.metadata_events.latest_chronologically

    assert_equal 50, events.length
    assert_equal 'github:5', events.first.github_identity
    assert_equal 'github:54', events.last.github_identity
  end
end
