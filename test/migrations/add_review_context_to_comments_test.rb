# frozen_string_literal: true
require 'test_helper'
require Rails.root.join('db/migrate/20260701000000_add_review_context_to_comments').to_s

class AddReviewContextToCommentsTest < ActiveSupport::TestCase
  test 'discards unverified legacy review rows before classifying retained comments' do
    subject = create(:subject)
    pending = create(:comment, subject: subject, review_state: 'pending', activity_kind: nil)
    review = create(:comment, subject: subject, review_state: 'APPROVED', activity_kind: nil)
    unverified_inline_comment = create(
      :comment,
      subject: subject,
      url: 'https://api.github.com/repos/octobox/octobox/pulls/comments/301',
      activity_kind: nil
    )
    issue_comment = create(
      :comment,
      subject: subject,
      url: 'https://api.github.com/repos/octobox/octobox/issues/comments/1',
      activity_kind: nil
    )

    AddReviewContextToComments.new.send(:classify_legacy_comments)

    refute Comment.exists?(pending.id)
    refute Comment.exists?(unverified_inline_comment.id)
    assert_equal 'pull_request_review', review.reload.activity_kind
    assert_equal 'issue_comment', issue_comment.reload.activity_kind
  end

  test 'deduplicates dirty identity groups before migration up adds unique indexes' do
    connection = ActiveRecord::Base.connection
    migration = AddReviewContextToComments.new
    connection.remove_index :comments, name: 'index_comments_on_subject_and_node_identity'
    connection.remove_index :comments, name: 'index_comments_on_subject_and_fallback_identity'

    subject = create(:subject)
    now = Time.current
    Comment.insert_all!([
      duplicate_row(subject, github_id: 501, github_node_id: 'NODE_DUPLICATE', body: 'old node', updated_at: now - 2.days),
      duplicate_row(subject, github_id: 502, github_node_id: 'NODE_DUPLICATE', body: 'new node', updated_at: now - 1.day),
      duplicate_row(subject, github_id: 601, activity_kind: 'issue_comment', body: 'old fallback', updated_at: now - 2.days),
      duplicate_row(subject, github_id: 601, activity_kind: 'issue_comment', body: 'new fallback', updated_at: now - 1.day)
    ])

    assert_nothing_raised { migration.up }

    assert_equal ['new node'], subject.comments.where(github_node_id: 'NODE_DUPLICATE').pluck(:body)
    assert_equal ['new fallback'], subject.comments.where(
      github_node_id: nil,
      github_id: 601,
      activity_kind: 'issue_comment'
    ).pluck(:body)
  end

  test 'defines only the subject-scoped partial identity indexes' do
    indexes = ActiveRecord::Base.connection.indexes(:comments).index_by(&:name)
    node_index = indexes.fetch('index_comments_on_subject_and_node_identity')
    fallback_index = indexes.fetch('index_comments_on_subject_and_fallback_identity')

    assert node_index.unique
    assert_equal %w[subject_id github_node_id], node_index.columns
    assert_includes node_index.where, 'github_node_id IS NOT NULL'

    assert fallback_index.unique
    assert_equal %w[subject_id activity_kind github_id], fallback_index.columns
    assert_includes fallback_index.where, 'github_node_id IS NULL'
    assert_includes fallback_index.where, 'github_id IS NOT NULL'
    assert_includes fallback_index.where, 'activity_kind IS NOT NULL'

    refute indexes.key?('index_comments_on_github_node_id')
    refute indexes.key?('index_comments_on_subject_id_and_github_id')
    refute indexes.key?('index_comments_on_subject_id_and_activity_kind')
  end

  private

  def duplicate_row(subject, github_id:, body:, updated_at:, github_node_id: nil, activity_kind: 'pull_request_review_comment')
    {
      subject_id: subject.id,
      github_id: github_id,
      github_node_id: github_node_id,
      activity_kind: activity_kind,
      author: 'reviewer',
      body: body,
      created_at: updated_at,
      updated_at: updated_at,
      review_context: {}
    }
  end
end
