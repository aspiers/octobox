class AddStateReasonToLifecycleEvents < ActiveRecord::Migration[7.1]
  def change
    add_column :lifecycle_events, :state_reason, :string
  end
end
