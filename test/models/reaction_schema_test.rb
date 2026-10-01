# frozen_string_literal: true
require 'test_helper'

class ReactionSchemaTest < ActiveSupport::TestCase
  test 'reaction summaries are additive non-null JSON columns' do
    subject_column = Subject.columns_hash.fetch('reactions')
    comment_column = Comment.columns_hash.fetch('reactions')

    assert_equal :jsonb, subject_column.type
    assert_equal :jsonb, comment_column.type
    refute subject_column.null
    refute comment_column.null
    assert_equal({}, JSON.parse(subject_column.default))
    assert_equal({}, JSON.parse(comment_column.default))
  end
end
