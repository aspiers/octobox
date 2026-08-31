class CreateMetadataEvents < ActiveRecord::Migration[7.1]
  def change
    create_table :metadata_event_snapshots do |t|
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

    create_table :metadata_events do |t|
      t.references :metadata_event_snapshot, null: false,
                   foreign_key: { on_delete: :cascade },
                   index: { name: 'index_metadata_events_on_snapshot_id' }
      t.string :github_identity, null: false
      t.string :event_type, null: false
      t.string :actor_login
      t.datetime :occurred_at, null: false
      t.jsonb :before_metadata, null: false, default: {}
      t.jsonb :after_metadata, null: false, default: {}
      t.jsonb :source_context, null: false, default: {}
      t.text :native_url
      t.bigint :github_event_id
      t.timestamps

      t.index [:metadata_event_snapshot_id, :github_identity], unique: true,
              name: 'index_metadata_events_on_snapshot_and_identity'
      t.index [:metadata_event_snapshot_id, :occurred_at],
              name: 'index_metadata_events_on_snapshot_and_time'
    end
  end
end
