class CreateLifecycleEvents < ActiveRecord::Migration[7.1]
  def change
    create_table :lifecycle_event_snapshots do |t|
      t.references :subject, null: false, foreign_key: { on_delete: :cascade }
      t.references :viewer, type: :integer, foreign_key: { to_table: :users, on_delete: :cascade }
      t.string :scope_key, null: false
      t.string :status, null: false, default: 'stale'
      t.integer :generation, null: false, default: 0
      t.integer :total_count, null: false, default: 0
      t.datetime :refresh_started_at
      t.datetime :refreshed_at
      t.datetime :failed_at
      t.timestamps

      t.index [:subject_id, :scope_key], unique: true
    end

    create_table :lifecycle_events do |t|
      t.references :lifecycle_event_snapshot, null: false,
                   foreign_key: { on_delete: :cascade },
                   index: { name: 'index_lifecycle_events_on_snapshot_id' }
      t.string :github_identity, null: false
      t.string :event_type, null: false
      t.string :actor_login
      t.datetime :occurred_at, null: false
      t.string :commit_sha
      t.string :before_commit_sha
      t.string :after_commit_sha
      t.string :ref_name
      t.string :previous_ref_name
      t.string :current_ref_name
      t.text :commit_message
      t.bigint :github_event_id
      t.timestamps

      t.index [:lifecycle_event_snapshot_id, :github_identity],
              unique: true,
              name: 'index_lifecycle_events_on_snapshot_and_identity'
      t.index [:lifecycle_event_snapshot_id, :occurred_at],
              name: 'index_lifecycle_events_on_snapshot_and_time'
    end
  end
end
