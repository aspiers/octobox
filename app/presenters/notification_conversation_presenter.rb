# frozen_string_literal: true

class NotificationConversationPresenter
  Page = Data.define(:entries, :remaining_count, :total_count)
  Entry = Data.define(:kind, :activity, :threads, :activity_at)
  Thread = Data.define(:root, :replies, :activity_at)

  def initialize(subject, lifecycle_events: [])
    @subject = subject
    @lifecycle_events = lifecycle_events
  end

  def page(limit: nil)
    entries = (build_entries + lifecycle_entries).sort_by do |entry|
      [entry.activity_at, entry.kind == :lifecycle_event ? 1 : 0, entry.activity.id]
    end
    visible_entries = limit ? entries.last(limit) : entries
    Page.new(
      entries: visible_entries,
      remaining_count: entries.length - visible_entries.length,
      total_count: entries.length
    )
  end

  private

  def lifecycle_entries
    @lifecycle_events.map do |event|
      Entry.new(kind: :lifecycle_event, activity: event, threads: [], activity_at: event.occurred_at)
    end
  end

  def build_entries
    return [] unless @subject.commentable?

    comments = @subject.comments.order(:created_at, :id).to_a.reject do |comment|
      comment.review_state.to_s.upcase == 'PENDING'
    end
    reviews = comments.select(&:review_submission?).index_by { |review| review.review_github_id || review.github_id }
    review_comments = comments.select(&:review_comment?)
    threads = build_threads(review_comments)
    threads_by_review = threads.group_by { |thread| thread.root.review_github_id }
    consumed_threads = Set.new

    entries = comments.filter_map do |comment|
      if comment.issue_comment?
        entry(:issue_comment, comment)
      elsif comment.review_activity?
        entry(:review_activity, comment)
      elsif comment.review_submission?
        review_threads = threads_by_review.fetch(comment.review_github_id || comment.github_id, [])
        review_threads.each { |thread| consumed_threads << thread.root.id }
        next if ignorable_commented_review?(comment, review_threads)
        entry(:review, comment, review_threads)
      end
    end

    threads.each do |thread|
      next if consumed_threads.include?(thread.root.id)
      entries << entry(:review_thread, thread.root, [thread])
    end

    entries
  end

  def build_threads(comments)
    by_github_id = comments.index_by(&:github_id)
    grouped = comments.group_by { |comment| root_for(comment, by_github_id).github_id }

    grouped.values.map do |thread_comments|
      root = thread_comments.find { |comment| comment.reply_to_github_id.blank? || !by_github_id.key?(comment.reply_to_github_id) }
      root ||= thread_comments.min_by { |comment| [comment.created_at, comment.id] }
      replies = thread_comments.reject { |comment| comment.id == root.id }.sort_by { |comment| [comment.created_at, comment.id] }
      Thread.new(root: root, replies: replies, activity_at: ([root] + replies).map(&:created_at).max)
    end
  end

  def root_for(comment, by_github_id)
    current = comment
    seen = Set.new

    while current.reply_to_github_id.present? && seen.add?(current.reply_to_github_id)
      parent = by_github_id[current.reply_to_github_id]
      break unless parent
      current = parent
    end

    current
  end

  def entry(kind, activity, threads = [])
    activity_at = ([activity.created_at] + threads.map(&:activity_at)).compact.max
    Entry.new(kind: kind, activity: activity, threads: threads, activity_at: activity_at)
  end

  def ignorable_commented_review?(review, threads)
    review.review_state == 'COMMENTED' && review.body.blank? && threads.empty?
  end
end
