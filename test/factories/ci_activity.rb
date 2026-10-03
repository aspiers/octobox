FactoryBot.define do
  factory :ci_activity do
    subject
    kind { "status" }
    sequence(:github_id, 9_000_000) { |n| n }
    head_sha { "a10867b14bb761a232cd80139fbd4c0d33264240" }
    sequence(:name) { |n| "continuous-integration/test-#{n}" }
    state { "success" }
    sequence(:target_url) { |n| "https://github.com/octobox/octobox/runs/#{n}" }
    github_created_at { Time.zone.parse("2026-08-31 12:00:00 UTC") }
    github_updated_at { Time.zone.parse("2026-08-31 12:01:00 UTC") }
  end
end
