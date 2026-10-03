# This file is auto-generated from the current state of the database. Instead
# of editing this file, please use the migrations feature of Active Record to
# incrementally modify your database, and then regenerate this schema definition.
#
# This file is the source Rails uses to define your schema when running `bin/rails
# db:schema:load`. When creating a new database, `bin/rails db:schema:load` tends to
# be faster and is potentially less error prone than running all of your
# migrations from scratch. Old migrations may fail to apply correctly if those
# migrations use external dependencies or application code.
#
# It's strongly recommended that you check this file into your version control system.

ActiveRecord::Schema[8.1].define(version: 2026_09_17_000000) do
  # These are extensions that must be enabled in order to support this database
  enable_extension "pg_catalog.plpgsql"
  enable_extension "pg_stat_statements"

  create_table "app_installation_permissions", force: :cascade do |t|
    t.integer "app_installation_id"
    t.integer "user_id"
    t.datetime "created_at", precision: nil, null: false
    t.datetime "updated_at", precision: nil, null: false
  end

  create_table "app_installations", force: :cascade do |t|
    t.bigint "github_id"
    t.bigint "app_id"
    t.string "account_login"
    t.bigint "account_id"
    t.string "account_type"
    t.string "target_type"
    t.bigint "target_id"
    t.string "permission_pull_requests"
    t.string "permission_issues"
    t.datetime "created_at", precision: nil, null: false
    t.datetime "updated_at", precision: nil, null: false
    t.string "permission_statuses"
    t.string "permission_checks"
  end

  create_table "ci_activities", force: :cascade do |t|
    t.bigint "subject_id", null: false
    t.string "kind", null: false
    t.bigint "github_id", null: false
    t.string "head_sha", null: false
    t.string "name", null: false
    t.string "state"
    t.string "conclusion"
    t.text "description"
    t.text "summary"
    t.string "app_name"
    t.bigint "check_suite_id"
    t.text "target_url"
    t.datetime "github_created_at"
    t.datetime "github_updated_at"
    t.datetime "started_at"
    t.datetime "completed_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["subject_id", "kind", "github_id"], name: "index_ci_activities_on_subject_kind_github_id", unique: true
  end

  create_table "comments", force: :cascade do |t|
    t.integer "subject_id"
    t.bigint "github_id"
    t.string "author"
    t.string "author_association"
    t.text "body"
    t.datetime "created_at", precision: nil, null: false
    t.datetime "updated_at", precision: nil, null: false
    t.string "review_state"
    t.string "url"
    t.string "html_url"
    t.string "activity_kind"
    t.string "github_node_id"
    t.bigint "review_github_id"
    t.bigint "reply_to_github_id"
    t.string "thread_github_node_id"
    t.jsonb "review_context", default: {}, null: false
    t.jsonb "reactions", default: {}, null: false
    t.index ["subject_id", "activity_kind", "github_id"], name: "index_comments_on_subject_and_fallback_identity", unique: true, where: "((github_node_id IS NULL) AND (github_id IS NOT NULL) AND (activity_kind IS NOT NULL))"
    t.index ["subject_id", "github_node_id"], name: "index_comments_on_subject_and_node_identity", unique: true, where: "(github_node_id IS NOT NULL)"
    t.index ["subject_id"], name: "index_comments_on_subject_id"
  end

  create_table "deployment_activity_snapshots", force: :cascade do |t|
    t.bigint "subject_id", null: false
    t.string "authorization_type", null: false
    t.bigint "authorization_id"
    t.jsonb "events", default: [], null: false
    t.integer "total_count", default: 0, null: false
    t.boolean "complete", default: false, null: false
    t.bigint "generation", default: 0, null: false
    t.datetime "fetched_at"
    t.datetime "refresh_requested_at"
    t.datetime "failed_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["subject_id", "authorization_type", "authorization_id"], name: "index_deployment_snapshots_on_authorized_scope", unique: true, where: "(authorization_id IS NOT NULL)"
    t.index ["subject_id", "authorization_type"], name: "index_deployment_snapshots_on_public_scope", unique: true, where: "(authorization_id IS NULL)"
    t.index ["subject_id"], name: "index_deployment_activity_snapshots_on_subject_id"
    t.check_constraint "authorization_type::text = 'public'::text AND authorization_id IS NULL OR (authorization_type::text = ANY (ARRAY['user'::character varying, 'installation'::character varying]::text[])) AND authorization_id IS NOT NULL", name: "deployment_snapshot_authorization_scope"
  end

  create_table "labels", force: :cascade do |t|
    t.string "name"
    t.string "color"
    t.bigint "subject_id"
    t.datetime "created_at", precision: nil, null: false
    t.datetime "updated_at", precision: nil, null: false
    t.bigint "github_id"
    t.index ["name"], name: "index_labels_on_name"
    t.index ["subject_id"], name: "index_labels_on_subject_id"
  end

  create_table "lifecycle_event_snapshots", force: :cascade do |t|
    t.bigint "subject_id", null: false
    t.integer "viewer_id"
    t.string "scope_key", null: false
    t.string "status", default: "stale", null: false
    t.integer "generation", default: 0, null: false
    t.integer "total_count", default: 0, null: false
    t.datetime "refresh_started_at"
    t.datetime "refreshed_at"
    t.datetime "failed_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["subject_id", "scope_key"], name: "index_lifecycle_event_snapshots_on_subject_id_and_scope_key", unique: true
    t.index ["subject_id"], name: "index_lifecycle_event_snapshots_on_subject_id"
    t.index ["viewer_id"], name: "index_lifecycle_event_snapshots_on_viewer_id"
  end

  create_table "lifecycle_events", force: :cascade do |t|
    t.bigint "lifecycle_event_snapshot_id", null: false
    t.string "github_identity", null: false
    t.string "event_type", null: false
    t.string "actor_login"
    t.datetime "occurred_at", null: false
    t.string "commit_sha"
    t.string "before_commit_sha"
    t.string "after_commit_sha"
    t.string "ref_name"
    t.string "previous_ref_name"
    t.string "current_ref_name"
    t.text "commit_message"
    t.bigint "github_event_id"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.string "state_reason"
    t.index ["lifecycle_event_snapshot_id", "github_identity"], name: "index_lifecycle_events_on_snapshot_and_identity", unique: true
    t.index ["lifecycle_event_snapshot_id", "occurred_at"], name: "index_lifecycle_events_on_snapshot_and_time"
    t.index ["lifecycle_event_snapshot_id"], name: "index_lifecycle_events_on_snapshot_id"
  end

  create_table "metadata_event_snapshots", force: :cascade do |t|
    t.bigint "subject_id", null: false
    t.integer "viewer_id"
    t.string "scope_key", null: false
    t.string "status", default: "stale", null: false
    t.integer "generation", default: 0, null: false
    t.integer "total_count", default: 0, null: false
    t.datetime "refresh_started_at"
    t.datetime "refreshed_at"
    t.datetime "failed_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["subject_id", "scope_key"], name: "index_metadata_event_snapshots_on_subject_id_and_scope_key", unique: true
    t.index ["subject_id"], name: "index_metadata_event_snapshots_on_subject_id"
    t.index ["viewer_id"], name: "index_metadata_event_snapshots_on_viewer_id"
  end

  create_table "metadata_events", force: :cascade do |t|
    t.bigint "metadata_event_snapshot_id", null: false
    t.string "github_identity", null: false
    t.string "event_type", null: false
    t.string "actor_login"
    t.datetime "occurred_at", null: false
    t.jsonb "before_metadata", default: {}, null: false
    t.jsonb "after_metadata", default: {}, null: false
    t.jsonb "source_context", default: {}, null: false
    t.text "native_url"
    t.bigint "github_event_id"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["metadata_event_snapshot_id", "github_identity"], name: "index_metadata_events_on_snapshot_and_identity", unique: true
    t.index ["metadata_event_snapshot_id", "occurred_at"], name: "index_metadata_events_on_snapshot_and_time"
    t.index ["metadata_event_snapshot_id"], name: "index_metadata_events_on_snapshot_id"
  end

  create_table "notifications", id: :serial, force: :cascade do |t|
    t.integer "user_id"
    t.bigint "github_id"
    t.integer "repository_id"
    t.string "repository_full_name"
    t.text "subject_title"
    t.string "subject_url"
    t.string "subject_type"
    t.string "reason"
    t.boolean "unread"
    t.string "last_read_at"
    t.string "url"
    t.boolean "archived", default: false
    t.datetime "created_at", precision: nil, null: false
    t.datetime "updated_at", precision: nil, null: false
    t.boolean "starred", default: false
    t.string "repository_owner_name", default: ""
    t.string "latest_comment_url"
    t.datetime "muted_at", precision: nil
    t.index ["muted_at"], name: "index_notifications_on_muted_at"
    t.index ["repository_full_name"], name: "index_notifications_on_repository_full_name"
    t.index ["subject_url"], name: "index_notifications_on_subject_url"
    t.index ["user_id", "archived", "updated_at"], name: "index_notifications_on_user_id_and_archived_and_updated_at"
    t.index ["user_id", "github_id"], name: "index_notifications_on_user_id_and_github_id", unique: true
  end

  create_table "pinned_searches", force: :cascade do |t|
    t.bigint "user_id"
    t.string "query"
    t.string "name"
    t.datetime "created_at", precision: nil, null: false
    t.datetime "updated_at", precision: nil, null: false
    t.index ["user_id"], name: "index_pinned_searches_on_user_id"
  end

  create_table "reference_activities", force: :cascade do |t|
    t.bigint "subject_id", null: false
    t.string "stable_identity", null: false
    t.bigint "github_id"
    t.string "github_node_id"
    t.string "activity_type", null: false
    t.string "source_type", null: false
    t.string "source_repository_full_name", null: false
    t.bigint "source_number"
    t.string "source_identifier"
    t.text "source_title"
    t.string "source_author"
    t.text "body_snippet"
    t.text "native_url", null: false
    t.datetime "occurred_at", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["subject_id", "occurred_at"], name: "index_reference_activities_on_subject_and_occurred_at"
    t.index ["subject_id", "stable_identity"], name: "index_reference_activities_on_subject_and_identity", unique: true
  end

  create_table "repositories", force: :cascade do |t|
    t.string "full_name", null: false
    t.bigint "github_id"
    t.boolean "private"
    t.string "owner"
    t.datetime "last_synced_at", precision: nil
    t.datetime "created_at", precision: nil, null: false
    t.datetime "updated_at", precision: nil, null: false
    t.integer "app_installation_id"
    t.index ["full_name"], name: "index_repositories_on_full_name", unique: true
    t.index ["github_id"], name: "index_repositories_on_github_id"
  end

  create_table "subjects", force: :cascade do |t|
    t.string "url"
    t.string "state"
    t.string "author"
    t.datetime "created_at", precision: nil, null: false
    t.datetime "updated_at", precision: nil, null: false
    t.string "html_url"
    t.string "assignees", default: "::"
    t.bigint "github_id"
    t.string "repository_full_name"
    t.boolean "locked"
    t.string "sha"
    t.string "status"
    t.text "body"
    t.integer "comment_count"
    t.boolean "draft", default: false
    t.string "title"
    t.jsonb "reactions", default: {}, null: false
    t.datetime "reference_activities_sync_started_at"
    t.index ["repository_full_name"], name: "index_subjects_on_repository_full_name"
    t.index ["url"], name: "index_subjects_on_url"
  end

  create_table "subscription_plans", force: :cascade do |t|
    t.bigint "github_id"
    t.string "name"
    t.string "description"
    t.integer "monthly_price_in_cents"
    t.integer "yearly_price_in_cents"
    t.string "price_model"
    t.boolean "has_free_trial"
    t.string "unit_name"
    t.datetime "created_at", precision: nil, null: false
    t.datetime "updated_at", precision: nil, null: false
    t.integer "number"
  end

  create_table "subscription_purchases", force: :cascade do |t|
    t.integer "subscription_plan_id"
    t.bigint "account_id"
    t.string "billing_cycle"
    t.integer "unit_count"
    t.boolean "on_free_trial"
    t.datetime "free_trial_ends_on", precision: nil
    t.datetime "next_billing_date", precision: nil
    t.datetime "created_at", precision: nil, null: false
    t.datetime "updated_at", precision: nil, null: false
    t.integer "oc_transactionid"
  end

  create_table "users", id: :serial, force: :cascade do |t|
    t.bigint "github_id", null: false
    t.string "github_login", null: false
    t.datetime "created_at", precision: nil, null: false
    t.datetime "updated_at", precision: nil, null: false
    t.datetime "last_synced_at", precision: nil
    t.integer "refresh_interval", default: 0
    t.string "api_token"
    t.string "sync_job_id"
    t.string "encrypted_access_token"
    t.string "encrypted_access_token_iv"
    t.string "encrypted_personal_access_token"
    t.string "encrypted_personal_access_token_iv"
    t.string "encrypted_app_token"
    t.string "encrypted_app_token_iv"
    t.string "theme", default: "light"
    t.boolean "display_comments", default: true
    t.boolean "disable_confirmations", default: false
    t.index ["api_token"], name: "index_users_on_api_token", unique: true
    t.index ["github_id"], name: "index_users_on_github_id", unique: true
  end

  add_foreign_key "ci_activities", "subjects", on_delete: :cascade
  add_foreign_key "deployment_activity_snapshots", "subjects", on_delete: :cascade
  add_foreign_key "labels", "subjects", on_update: :cascade, on_delete: :cascade
  add_foreign_key "lifecycle_event_snapshots", "subjects", on_delete: :cascade
  add_foreign_key "lifecycle_event_snapshots", "users", column: "viewer_id", on_delete: :cascade
  add_foreign_key "lifecycle_events", "lifecycle_event_snapshots", on_delete: :cascade
  add_foreign_key "metadata_event_snapshots", "subjects", on_delete: :cascade
  add_foreign_key "metadata_event_snapshots", "users", column: "viewer_id", on_delete: :cascade
  add_foreign_key "metadata_events", "metadata_event_snapshots", on_delete: :cascade
  add_foreign_key "reference_activities", "subjects", on_delete: :cascade
end
