# frozen_string_literal: true

require "test_helper"

class ReferenceActivityTest < ActiveSupport::TestCase
  test "requires a stable identity unique within its subject" do
    activity = create(:reference_activity)
    duplicate = build(:reference_activity, subject: activity.subject, stable_identity: activity.stable_identity)

    refute duplicate.valid?
    assert_includes duplicate.errors[:stable_identity], "has already been taken"
  end

  test "orders activity chronologically with a stable tie breaker" do
    subject = create(:subject)
    later = create(:reference_activity, subject: subject, occurred_at: 2.hours.ago)
    first_at_same_time = create(:reference_activity, subject: subject, occurred_at: 3.hours.ago)
    second_at_same_time = create(:reference_activity, subject: subject, occurred_at: 3.hours.ago)

    assert_equal [first_at_same_time, second_at_same_time, later], subject.reference_activities.chronological.to_a
  end

  test "allows links only to the configured GitHub host" do
    activity = build(:reference_activity, native_url: "https://github.com/example/source/issues/1")
    assert_equal activity.native_url, activity.safe_native_url

    activity.native_url = "javascript:alert(1)"
    assert_nil activity.safe_native_url

    activity.native_url = "https://token@github.com/example/source/issues/1"
    assert_nil activity.safe_native_url

    activity.native_url = "https://example.test/source/issues/1"
    assert_nil activity.safe_native_url
  end

  test "deletes reference activity with its subject" do
    activity = create(:reference_activity)

    activity.subject.destroy

    refute ReferenceActivity.exists?(activity.id)
  end
end
