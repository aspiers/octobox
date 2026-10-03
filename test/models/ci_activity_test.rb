# frozen_string_literal: true

require "test_helper"

class CiActivityTest < ActiveSupport::TestCase
  test "belongs to a subject and is deleted with it" do
    activity = create(:ci_activity)

    activity.subject.destroy

    refute CiActivity.exists?(activity.id)
  end

  test "requires a unique GitHub identity within its subject and kind" do
    activity = create(:ci_activity)
    duplicate = build(
      :ci_activity,
      subject: activity.subject,
      kind: activity.kind,
      github_id: activity.github_id
    )

    refute duplicate.valid?
    assert_includes duplicate.errors[:github_id], "has already been taken"
  end

  test "maps GitHub states and conclusions to preview outcomes" do
    cases = {
      ["check_run", "in_progress", nil] => "pending",
      ["check_run", "completed", "success"] => "success",
      ["check_run", "completed", "timed_out"] => "failure",
      ["check_run", "completed", "cancelled"] => "cancelled",
      ["check_run", "completed", "skipped"] => "skipped",
      ["check_run", "completed", "neutral"] => "neutral",
      ["check_run", "completed", "action_required"] => "action_required",
      ["status", "error", nil] => "failure"
    }

    cases.each do |(kind, state, conclusion), expected|
      activity = build(:ci_activity, kind: kind, state: state, conclusion: conclusion)
      assert_equal expected, activity.outcome
    end
  end

  test "orders activity by its latest GitHub timestamp" do
    subject = create(:subject)
    older = create(:ci_activity, subject: subject, github_updated_at: 2.hours.ago)
    newer = create(:ci_activity, subject: subject, github_updated_at: 1.hour.ago)

    assert_equal [newer, older], subject.ci_activities.recent_first.to_a
  end

  test "allows only absolute HTTP and HTTPS target URLs without credentials" do
    activity = build(:ci_activity, target_url: "https://ci.example.test/runs/1")
    assert_equal "https://ci.example.test/runs/1", activity.safe_target_url

    activity.target_url = "javascript:alert(1)"
    assert_nil activity.safe_target_url

    activity.target_url = "https://token@ci.example.test/runs/1"
    assert_nil activity.safe_target_url
  end
end
