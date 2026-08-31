class CreateReferenceActivities < ActiveRecord::Migration[7.1]
  def change
    add_column :subjects, :reference_activities_sync_started_at, :datetime

    create_table :reference_activities do |t|
      t.references :subject, null: false, index: false, foreign_key: { on_delete: :cascade }
      t.string :stable_identity, null: false
      t.bigint :github_id
      t.string :github_node_id
      t.string :activity_type, null: false
      t.string :source_type, null: false
      t.string :source_repository_full_name, null: false
      t.bigint :source_number
      t.string :source_identifier
      t.text :source_title
      t.string :source_author
      t.text :body_snippet
      t.text :native_url, null: false
      t.datetime :occurred_at, null: false
      t.timestamps

      t.index [:subject_id, :stable_identity],
              unique: true,
              name: "index_reference_activities_on_subject_and_identity"
      t.index [:subject_id, :occurred_at],
              name: "index_reference_activities_on_subject_and_occurred_at"
    end
  end
end
