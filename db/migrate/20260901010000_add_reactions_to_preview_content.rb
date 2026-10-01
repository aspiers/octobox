class AddReactionsToPreviewContent < ActiveRecord::Migration[7.1]
  def change
    add_column :subjects, :reactions, :jsonb, default: {}, null: false
    add_column :comments, :reactions, :jsonb, default: {}, null: false
  end
end
