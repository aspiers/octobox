# frozen_string_literal: true

require 'test_helper'

class DeploymentActivitySnapshotSchemaTest < ActiveSupport::TestCase
  test 'migration uses Rails 7.1 and creates isolated authorization indexes' do
    migration_path = Rails.root.join('db/migrate/20260901000000_create_deployment_activity_snapshots.rb')
    assert_includes migration_path.read, 'ActiveRecord::Migration[7.1]'

    indexes = ActiveRecord::Base.connection.indexes(:deployment_activity_snapshots)
    public_index = indexes.find { |index| index.name == 'index_deployment_snapshots_on_public_scope' }
    authorized_index = indexes.find { |index| index.name == 'index_deployment_snapshots_on_authorized_scope' }

    assert public_index.unique
    assert_equal '(authorization_id IS NULL)', public_index.where
    assert authorized_index.unique
    assert_equal '(authorization_id IS NOT NULL)', authorized_index.where
  end
end
