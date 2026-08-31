class AddReviewContextToComments < ActiveRecord::Migration[7.1]
  def up
    add_review_context_columns unless column_exists?(:comments, :activity_kind)

    classify_legacy_comments
    deduplicate_identity_groups

    add_index :comments, [:subject_id, :github_node_id], unique: true,
      where: 'github_node_id IS NOT NULL', name: 'index_comments_on_subject_and_node_identity' unless
        index_exists?(:comments, name: 'index_comments_on_subject_and_node_identity')
    add_index :comments, [:subject_id, :activity_kind, :github_id], unique: true,
      where: 'github_node_id IS NULL AND github_id IS NOT NULL AND activity_kind IS NOT NULL',
      name: 'index_comments_on_subject_and_fallback_identity' unless
        index_exists?(:comments, name: 'index_comments_on_subject_and_fallback_identity')
  end

  def down
    remove_index :comments, name: 'index_comments_on_subject_and_fallback_identity'
    remove_index :comments, name: 'index_comments_on_subject_and_node_identity'

    change_table :comments, bulk: true do |t|
      t.remove :html_url, :activity_kind, :github_node_id, :review_github_id,
        :reply_to_github_id, :thread_github_node_id, :review_context
    end
  end

  private

  def add_review_context_columns
    change_table :comments, bulk: true do |t|
      t.string :html_url
      t.string :activity_kind
      t.string :github_node_id
      t.bigint :review_github_id
      t.bigint :reply_to_github_id
      t.string :thread_github_node_id
      t.jsonb :review_context, null: false, default: {}
    end
  end

  def classify_legacy_comments
    execute <<~SQL.squish
      DELETE FROM comments
      WHERE UPPER(COALESCE(review_state, '')) = 'PENDING'
         OR url LIKE '%/pulls/comments/%'
    SQL

    execute <<~SQL.squish
      UPDATE comments
      SET activity_kind = 'pull_request_review'
      WHERE activity_kind IS NULL AND review_state IS NOT NULL
    SQL

    execute <<~SQL.squish
      UPDATE comments
      SET activity_kind = 'issue_comment'
      WHERE activity_kind IS NULL
    SQL
  end

  def deduplicate_identity_groups
    delete_ranked_duplicates(
      'github_node_id IS NOT NULL',
      'PARTITION BY subject_id, github_node_id ORDER BY updated_at DESC NULLS LAST, id DESC'
    )
    delete_ranked_duplicates(
      'github_node_id IS NULL AND github_id IS NOT NULL AND activity_kind IS NOT NULL',
      'PARTITION BY subject_id, activity_kind, github_id ORDER BY updated_at DESC NULLS LAST, id DESC'
    )
  end

  def delete_ranked_duplicates(filter, window)
    execute <<~SQL.squish
      DELETE FROM comments
      USING (
        SELECT id, ROW_NUMBER() OVER (#{window}) AS duplicate_rank
        FROM comments
        WHERE #{filter}
      ) ranked_comments
      WHERE comments.id = ranked_comments.id
        AND ranked_comments.duplicate_rank > 1
    SQL
  end
end
