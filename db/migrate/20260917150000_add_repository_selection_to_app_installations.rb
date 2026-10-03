class AddRepositorySelectionToAppInstallations < ActiveRecord::Migration[7.1]
  def change
    add_column :app_installations, :repository_selection, :string
  end
end
