# frozen_string_literal: true

require "test_helper"
require Rails.root.join("db/migrate/20260902000000_create_reference_activities")

class CreateReferenceActivitiesTest < ActiveSupport::TestCase
  test "uses Rails 7.1 migration compatibility and creates the reference schema" do
    assert_equal ActiveRecord::Migration[7.1], CreateReferenceActivities.superclass

    columns = ActiveRecord::Base.connection.columns(:reference_activities).index_by(&:name)
    assert columns.fetch("subject_id").null == false
    assert columns.fetch("stable_identity").null == false
    assert columns.fetch("native_url").null == false
    assert ActiveRecord::Base.connection.column_exists?(:subjects, :reference_activities_sync_started_at)

    identity_index = ActiveRecord::Base.connection.indexes(:reference_activities)
      .find { |index| index.name == "index_reference_activities_on_subject_and_identity" }
    assert identity_index.unique
    assert_equal %w[subject_id stable_identity], identity_index.columns

    foreign_key = ActiveRecord::Base.connection.foreign_keys(:reference_activities)
      .find { |key| key.to_table == "subjects" }
    assert_equal :cascade, foreign_key.on_delete
  end
end
