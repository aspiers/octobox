class CreateCiActivities < ActiveRecord::Migration[7.1]
  def change
    add_column :app_installations, :permission_checks, :string

    create_table :ci_activities do |t|
      t.references :subject, null: false, index: false, foreign_key: { on_delete: :cascade }
      t.string :kind, null: false
      t.bigint :github_id, null: false
      t.string :head_sha, null: false
      t.string :name, null: false
      t.string :state
      t.string :conclusion
      t.text :description
      t.text :summary
      t.string :app_name
      t.bigint :check_suite_id
      t.text :target_url
      t.datetime :github_created_at
      t.datetime :github_updated_at
      t.datetime :started_at
      t.datetime :completed_at
      t.timestamps

      t.index [:subject_id, :kind, :github_id],
              unique: true,
              name: "index_ci_activities_on_subject_kind_github_id"
    end
  end
end
