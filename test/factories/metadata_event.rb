FactoryBot.define do
  factory :metadata_event_snapshot do
    subject
    scope_key { 'public' }
    status { 'complete' }
    generation { 1 }
    total_count { 1 }
    refreshed_at { Time.current }
  end

  factory :metadata_event do
    metadata_event_snapshot
    sequence(:github_identity) { |n| "github:metadata-#{n}" }
    event_type { 'renamed' }
    actor_login { 'octocat' }
    occurred_at { Time.utc(2026, 8, 31, 12) }
    before_metadata { { 'title' => 'Old title' } }
    after_metadata { { 'title' => 'New title' } }
    source_context { {} }
  end
end
