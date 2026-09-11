class AddGithubAppRefreshCredentialsToUsers < ActiveRecord::Migration[7.1]
  def change
    add_column :users, :encrypted_app_refresh_token, :string
    add_column :users, :encrypted_app_refresh_token_iv, :string
    add_column :users, :app_token_expires_at, :datetime
  end
end
