FactoryBot.define do
  factory :lifecycle_event_snapshot do
    subject
    scope_key { 'public' }
    status { 'complete' }
    generation { 1 }
    total_count { 1 }
    refreshed_at { Time.current }
  end

  factory :lifecycle_event do
    lifecycle_event_snapshot
    sequence(:github_identity) { |n| "github:event-#{n}" }
    event_type { 'closed' }
    actor_login { 'octocat' }
    sequence(:occurred_at) { |n| Time.utc(2026, 8, 1) + n.minutes }
  end
end
