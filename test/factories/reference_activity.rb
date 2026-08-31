FactoryBot.define do
  factory :reference_activity do
    subject
    sequence(:stable_identity) { |n| "node:reference-#{n}" }
    sequence(:github_id, 8_000_000) { |n| n }
    activity_type { "cross_reference" }
    source_type { "issue" }
    source_repository_full_name { "example/source" }
    sequence(:source_number, 100) { |n| n }
    sequence(:source_identifier) { |n| "I_reference_#{n}" }
    sequence(:source_title) { |n| "Reference #{n}" }
    source_author { "alice" }
    body_snippet { "Context from the source." }
    sequence(:native_url) { |n| "https://github.com/example/source/issues/#{n}" }
    occurred_at { Time.zone.parse("2026-08-27 17:51:59 UTC") }
  end
end
