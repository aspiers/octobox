class CreateDeploymentActivitySnapshots < ActiveRecord::Migration[7.1]
  def change
    create_table :deployment_activity_snapshots do |t|
      t.references :subject, null: false, foreign_key: { on_delete: :cascade }
      t.string :authorization_type, null: false
      t.bigint :authorization_id
      t.jsonb :events, null: false, default: []
      t.integer :total_count, null: false, default: 0
      t.boolean :complete, null: false, default: false
      t.bigint :generation, null: false, default: 0
      t.datetime :fetched_at
      t.datetime :refresh_requested_at
      t.datetime :failed_at
      t.timestamps
    end

    add_index :deployment_activity_snapshots,
              [:subject_id, :authorization_type],
              unique: true,
              where: 'authorization_id IS NULL',
              name: 'index_deployment_snapshots_on_public_scope'
    add_index :deployment_activity_snapshots,
              [:subject_id, :authorization_type, :authorization_id],
              unique: true,
              where: 'authorization_id IS NOT NULL',
              name: 'index_deployment_snapshots_on_authorized_scope'
    add_check_constraint :deployment_activity_snapshots,
                         "(authorization_type = 'public' AND authorization_id IS NULL) OR " \
                         "(authorization_type IN ('user', 'installation') AND authorization_id IS NOT NULL)",
                         name: 'deployment_snapshot_authorization_scope'
  end
end
