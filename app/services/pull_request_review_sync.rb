# frozen_string_literal: true

class PullRequestReviewSync
  REVIEW_EVENTS = %w[reviewed review_requested review_request_removed review_dismissed].freeze
  GRAPHQL_PAGE_SIZE = 100
  MAX_GRAPHQL_PAGES = 20
  REST_REVIEW_CONTEXT_KEYS = %w[
    path diff_hunk commit_id original_commit_id line original_line start_line
    original_start_line side start_side position original_position subject_type
    outdated thread_root_github_id
  ].freeze

  REVIEW_THREADS_QUERY = <<~GRAPHQL.freeze
    query PullRequestReviewThreads($owner: String!, $name: String!, $number: Int!, $after: String) {
      repository(owner: $owner, name: $name) {
        pullRequest(number: $number) {
          reviewThreads(first: 100, after: $after) {
            nodes {
              id
              isCollapsed
              isOutdated
              isResolved
              path
              line
              originalLine
              startLine
              originalStartLine
              diffSide
              startDiffSide
              comments(first: 1) {
                nodes { databaseId id }
              }
            }
            pageInfo { hasNextPage endCursor }
          }
        }
      }
    }
  GRAPHQL

  def initialize(subject, client:)
    @subject = subject
    @client = client
  end

  def sync
    snapshot = fetch_snapshot
    return false unless snapshot

    @subject.with_lock { persist_snapshot(*snapshot) }
    true
  end

  private

  def fetch_snapshot
    timeline = fetch_timeline
    return unless timeline

    remote_comments = fetch_review_comments
    return unless remote_comments

    review_events = timeline.select { |event| REVIEW_EVENTS.include?(value(event, :event).to_s) }
    submitted_review_ids = review_events.filter_map do |event|
      value(event, :id).to_i if submitted_review?(event)
    end
    retained_comments = retained_review_comments(remote_comments, submitted_review_ids)
    thread_contexts = fetch_thread_contexts if retained_comments.present?
    [review_events, retained_comments, thread_contexts]
  end

  def persist_snapshot(review_events, retained_comments, thread_contexts)
    changed = delete_pending_rows.positive?
    review_events.each { |event| changed = sync_review_event(event) || changed }
    changed = sync_review_comments(retained_comments, thread_contexts) || changed
    changed = reconcile_review_comments(retained_comments).positive? || changed

    @subject.update_column(:comment_count, @subject.comments.count)
    changed
  end

  def fetch_timeline
    fetch_rest_snapshot('timeline') do
      @client.issue_timeline(repository_name, pull_number)
    end
  end

  def fetch_review_comments
    fetch_rest_snapshot('comments') do
      @client.pull_request_comments(repository_name, pull_number)
    end
  end

  def fetch_rest_snapshot(part)
    snapshot = yield
    raise IncompleteSnapshot, 'GitHub response still has a next page' unless rest_snapshot_complete?
    snapshot
  rescue Octokit::Error, Faraday::Error, IncompleteSnapshot => error
    log_failure(part, error)
    nil
  end

  def rest_snapshot_complete?
    return true unless @client.is_a?(Octokit::Client)
    response = @client.last_response
    response.present? && response.rels[:next].blank?
  end

  def fetch_thread_contexts
    contexts = {}
    cursor = nil

    MAX_GRAPHQL_PAGES.times do
      # Octokit reserves symbol :query for URL parameters, so GraphQL body keys stay strings.
      response = @client.post('graphql', {
        'query' => REVIEW_THREADS_QUERY,
        'variables' => {
          'owner' => repository_owner,
          'name' => repository_short_name,
          'number' => pull_number,
          'after' => cursor
        }
      })
      raise GraphqlFailure, 'GitHub returned GraphQL errors' if value(response, :errors).present?

      threads = dig_value(response, :data, :repository, :pullRequest, :reviewThreads)
      return nil unless threads

      Array(value(threads, :nodes)).each do |thread|
        root = Array(dig_value(thread, :comments, :nodes)).first
        root_id = value(root, :databaseId)
        contexts[root_id.to_i] = thread_context(thread) if root_id
      end

      page_info = value(threads, :pageInfo)
      return contexts unless value(page_info, :hasNextPage)

      cursor = value(page_info, :endCursor)
      raise GraphqlFailure, 'GitHub returned no review thread cursor' if cursor.blank?
    end

    raise GraphqlFailure, "GitHub review threads exceeded #{GRAPHQL_PAGE_SIZE * MAX_GRAPHQL_PAGES} records"
  rescue Octokit::Error, Faraday::Error, GraphqlFailure => error
    log_failure('GraphQL review threads', error)
    nil
  end

  def sync_review_event(event)
    kind = event_kind(event)
    return false if kind.nil? || pending_review?(event)

    github_id = value(event, :id)
    comment = find_comment(kind, github_id, value(event, :node_id))
    attributes = event_attributes(event, kind)
    assign_remote_attributes(comment, attributes)
    return false unless comment.changed?

    comment.save!
    true
  end

  def retained_review_comments(remote_comments, submitted_review_ids)
    Array(remote_comments).select do |comment|
      review_id = value(comment, :pull_request_review_id)
      review_id.blank? || submitted_review_ids.include?(review_id.to_i)
    end
  end

  def sync_review_comments(comments, thread_contexts)
    by_id = comments.index_by { |comment| value(comment, :id).to_i }
    changed = false

    comments.each do |remote_comment|
      github_id = value(remote_comment, :id)
      comment = find_comment('pull_request_review_comment', github_id, value(remote_comment, :node_id))
      context = comment.review_context.except(*REST_REVIEW_CONTEXT_KEYS)
      context.merge!(review_comment_context(remote_comment))
      root_id = thread_root_id(remote_comment, by_id)
      context['thread_root_github_id'] = root_id

      graphql_context = thread_contexts&.fetch(root_id, nil)
      context.merge!(graphql_context.fetch(:context)) if graphql_context

      attributes = {
        author: dig_value(remote_comment, :user, :login) || 'ghost',
        author_association: value(remote_comment, :author_association),
        body: clean_body(value(remote_comment, :body)),
        created_at: value(remote_comment, :created_at) || Time.current,
        updated_at: value(remote_comment, :updated_at) || value(remote_comment, :created_at) || Time.current,
        url: value(remote_comment, :url),
        html_url: value(remote_comment, :html_url),
        activity_kind: 'pull_request_review_comment',
        github_node_id: value(remote_comment, :node_id),
        review_github_id: value(remote_comment, :pull_request_review_id),
        reply_to_github_id: value(remote_comment, :in_reply_to_id),
        thread_github_node_id: graphql_context&.fetch(:thread_id) || comment.thread_github_node_id,
        review_context: context,
        reactions: ReactionSummary.from(remote_comment)
      }
      assign_remote_attributes(comment, attributes)
      next unless comment.changed?

      comment.save!
      changed = true
    end

    changed
  end

  def reconcile_review_comments(remote_comments)
    remote_ids = remote_comments.filter_map do |comment|
      github_id = value(comment, :id)
      github_id.to_i if github_id.present?
    end
    scope = @subject.comments.where(activity_kind: 'pull_request_review_comment')
    return scope.delete_all if remote_ids.empty?

    scope.where(github_id: nil).or(scope.where.not(github_id: remote_ids)).delete_all
  end

  def delete_pending_rows
    @subject.comments.where("UPPER(COALESCE(review_state, '')) = 'PENDING'").delete_all
  end

  def event_attributes(event, kind)
    review_id = if kind == 'pull_request_review'
      value(event, :id)
    elsif kind == 'review_dismissed'
      dig_value(event, :dismissed_review, :review_id)
    end

    {
      author: event_author(event) || 'ghost',
      author_association: value(event, :author_association),
      body: clean_body(value(event, :body)),
      created_at: value(event, :submitted_at) || value(event, :created_at) || Time.current,
      updated_at: value(event, :submitted_at) || value(event, :created_at) || Time.current,
      review_state: kind == 'pull_request_review' ? normalized_state(event) : nil,
      url: value(event, :url),
      html_url: event_html_url(event, review_id),
      activity_kind: kind,
      github_node_id: value(event, :node_id),
      review_github_id: review_id,
      review_context: event_context(event, kind)
    }
  end

  def assign_remote_attributes(comment, attributes)
    attributes = attributes.compact
    if comment.body.present? && attributes[:body].blank? &&
        comment.activity_kind == 'pull_request_review' && comment.review_state == 'COMMENTED'
      attributes.delete(:body)
    end
    comment.assign_attributes(attributes)
  end

  def find_comment(kind, github_id, node_id)
    comment = @subject.comments.find_by(github_node_id: node_id) if node_id.present?
    comment ||= @subject.comments.where(github_id: github_id, activity_kind: [nil, kind]).first if github_id.present?
    comment || @subject.comments.new(github_id: github_id)
  end

  def event_kind(event)
    case value(event, :event).to_s
    when 'reviewed' then 'pull_request_review'
    when 'review_requested' then 'review_requested'
    when 'review_request_removed' then 'review_request_removed'
    when 'review_dismissed' then 'review_dismissed'
    end
  end

  def event_context(event, kind)
    context = {}
    context['commit_id'] = value(event, :commit_id) if value(event, :commit_id)

    if %w[review_requested review_request_removed].include?(kind)
      context['review_requester'] = actor_context(value(event, :review_requester))
      context['requested_reviewer'] = actor_context(value(event, :requested_reviewer))
      context['requested_team'] = team_context(value(event, :requested_team))
    elsif kind == 'review_dismissed'
      dismissed = value(event, :dismissed_review)
      context['dismissed_review'] = {
        'state' => value(dismissed, :state),
        'review_id' => value(dismissed, :review_id),
        'dismissal_message' => value(dismissed, :dismissal_message),
        'dismissal_commit_id' => value(dismissed, :dismissal_commit_id)
      }.compact
    end

    context.compact
  end

  def review_comment_context(comment)
    keys = %i[path diff_hunk commit_id original_commit_id line original_line start_line
              original_start_line side start_side position original_position subject_type]
    context = keys.each_with_object({}) do |key, result|
      remote_key = key == :start_side ? :start_side : key
      result[key.to_s] = value(comment, remote_key)
    end

    has_position = !value(comment, :original_position).nil? || !value(comment, :original_line).nil?
    context['outdated'] = value(comment, :position).nil? && value(comment, :line).nil? if has_position
    context
  end

  def thread_context(thread)
    context = {
      'resolved' => value(thread, :isResolved),
      'outdated' => value(thread, :isOutdated),
      'collapsed' => value(thread, :isCollapsed),
      'path' => value(thread, :path),
      'line' => value(thread, :line),
      'original_line' => value(thread, :originalLine),
      'start_line' => value(thread, :startLine),
      'original_start_line' => value(thread, :originalStartLine),
      'side' => value(thread, :diffSide),
      'start_side' => value(thread, :startDiffSide)
    }.compact
    {thread_id: value(thread, :id), context: context}
  end

  def thread_root_id(comment, by_id)
    current = comment
    seen = Set.new

    while (parent_id = value(current, :in_reply_to_id)).present? && seen.add?(parent_id.to_i)
      parent = by_id[parent_id.to_i]
      break unless parent
      current = parent
    end

    value(current, :id).to_i
  end

  def submitted_review?(event)
    value(event, :event).to_s == 'reviewed' && !pending_review?(event)
  end

  def pending_review?(event)
    value(event, :event).to_s == 'reviewed' && normalized_state(event) == 'PENDING'
  end

  def normalized_state(event)
    value(event, :state).to_s.upcase.presence
  end

  def event_author(event)
    dig_value(event, :user, :login) || dig_value(event, :actor, :login) ||
      dig_value(event, :review_requester, :login)
  end

  def event_html_url(event, review_id)
    value(event, :html_url) ||
      (review_id ? "#{@subject.html_url}#pullrequestreview-#{review_id}" : @subject.html_url)
  end

  def actor_context(actor)
    return unless actor
    {
      'login' => value(actor, :login),
      'type' => value(actor, :type),
      'html_url' => value(actor, :html_url)
    }.compact
  end

  def team_context(team)
    return unless team
    {
      'name' => value(team, :name),
      'slug' => value(team, :slug),
      'html_url' => value(team, :html_url)
    }.compact
  end

  def clean_body(body)
    body&.gsub("\u0000", '')
  end

  def repository_name
    @subject.repository_full_name
  end

  def repository_owner
    repository_name.split('/', 2).first
  end

  def repository_short_name
    repository_name.split('/', 2).last
  end

  def pull_number
    @subject.url[%r{/pulls?/(\d+)}, 1].to_i
  end

  def dig_value(object, *keys)
    keys.reduce(object) { |memo, key| value(memo, key) }
  end

  def value(object, key)
    return if object.nil?
    if object.respond_to?(:key?)
      return object[key] if object.key?(key)
      return object[key.to_s] if object.key?(key.to_s)
    end
    object[key]
  rescue NoMethodError, TypeError
    nil
  end

  def log_failure(part, error)
    Rails.logger.warn("Pull request review #{part} sync failed for #{@subject.url}: #{error.class}: #{error.message}")
  end

  class GraphqlFailure < StandardError; end
  class IncompleteSnapshot < StandardError; end
  private_constant :GraphqlFailure, :IncompleteSnapshot
end
