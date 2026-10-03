# frozen_string_literal: true

require 'test_helper'

class LifecycleEventTest < ActiveSupport::TestCase
  test 'accepts only lifecycle event types' do
    event = build(:lifecycle_event, event_type: 'labeled')

    refute event.valid?
    assert_includes event.errors[:event_type], 'is not included in the list'
  end

  test 'latest events are returned chronologically' do
    snapshot = create(:lifecycle_event_snapshot, total_count: 55)
    events = 55.times.map do |index|
      create(:lifecycle_event, lifecycle_event_snapshot: snapshot, occurred_at: index.minutes.ago)
    end

    latest = snapshot.lifecycle_events.latest_chronologically(50)

    assert_equal 50, latest.length
    assert_equal events.first, latest.last
    assert_operator latest.first.occurred_at, :<, latest.last.occurred_at
  end

  test 'stable identities are unique within a snapshot' do
    event = create(:lifecycle_event)
    duplicate = build(
      :lifecycle_event,
      lifecycle_event_snapshot: event.lifecycle_event_snapshot,
      github_identity: event.github_identity
    )

    refute duplicate.valid?
  end
end
