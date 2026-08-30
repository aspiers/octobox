# frozen_string_literal: true

class CreateNotificationUndoActions < ActiveRecord::Migration[7.1]
  def change
    create_table :notification_undo_actions do |t|
      t.references :user, null: false, type: :integer, foreign_key: true
      t.string :token, null: false
      t.string :action_type, null: false
      t.integer :snapshot_version, null: false, default: 1
      t.jsonb :states, null: false, default: []
      t.timestamps
    end

    add_index :notification_undo_actions, :token, unique: true
  end
end
