class Subject < ApplicationRecord
  has_many :notifications, foreign_key: :subject_url, primary_key: :url
  has_many :labels, dependent: :delete_all
  has_many :users, through: :notifications
  has_many :comments, dependent: :delete_all
  belongs_to :repository, foreign_key: :repository_full_name, primary_key: :full_name, optional: true
  has_one :app_installation, through: :repository

  BOT_AUTHOR_REGEX = /\A(.*)\[bot\]\z/.freeze
  private_constant :BOT_AUTHOR_REGEX

  scope :label, ->(label_name) { joins(:labels).where(Label.arel_table[:name].matches(label_name)) }

  validates :url, presence: true, uniqueness: true

  after_save :push_to_channels

  def update_labels(remote_labels)
    existing_labels = labels.to_a
    remote_labels.each do |l|
      label = labels.find_by_github_id(l['id'])
      if label.nil?
        labels.create({
          github_id: l['id'],
          color: l['color'],
          name: l['name'],
        })
      else
        label.github_id = l['id'] # smoothly migrate legacy labels
        label.color = l['color']
        label.name = l['name']
        label.save if label.changed?
      end
    end

    remote_label_ids = remote_labels.map{|l| l['id'] }
    deleted_labels = existing_labels.reject{|l| remote_label_ids.include?(l.github_id) }
    deleted_labels.each(&:destroy)
    push_to_channels if existing_labels != labels.to_a
  end

  def sync_involved_users
    return unless Octobox.github_app?
    involved_user_ids.each { |user_id| SyncNotificationsWorker.perform_in(1.minutes, user_id) }
  end

  def sync(remote_subject, github_client: nil)
    @preferred_github_client = github_client
    attributes = {
      repository_full_name: extract_full_name_from_remote_subject(remote_subject),
      github_id: remote_subject['id'],
      state: remote_subject['merged_at'].present? ? 'merged' : remote_subject['state'],
      author: remote_subject.fetch('user', {})['login'],
      html_url: remote_subject['html_url'],
      created_at: remote_subject['created_at'] || Time.current,
      updated_at: remote_subject['updated_at'] || Time.current,
      comment_count: extract_comment_count_from_remote_subject(remote_subject) || comment_count,
      assignees: ":#{Array(remote_subject['assignees'].try(:map) {|a| a['login'] }).join(':')}:",
      locked: remote_subject['locked'],
      sha: remote_subject.fetch('head', {})['sha'],
      body: remote_subject['body'].try(:gsub, "\u0000", ''),
      draft: remote_subject['draft'],
      title: remote_subject['title']
    }
    reaction_counts = ReactionSummary.from(remote_subject)
    attributes[:reactions] = reaction_counts unless reaction_counts.nil?
    update(attributes)

    return unless persisted?

    update_labels(remote_subject['labels']) if remote_subject['labels'].present?
    update_comments if Octobox.include_comments? && (has_comments? || pull_request?)
    update_status
    sync_involved_users if (saved_changes.keys & notifiable_fields).any?
  ensure
    @preferred_github_client = nil
  end

  def self.sync(remote_subject, github_client: nil)
    subject = Subject.find_or_create_by(url: remote_subject['url'])
    subject.sync(remote_subject, github_client: github_client)
    subject
  end

  def self.sync_status(sha, repository_full_name)
    where(repository_full_name: repository_full_name).find_by_sha(sha)&.update_status
  end

  def self.sync_comments(remote_subject)
    return if remote_subject.nil?
    subject = Subject.find_by(url: remote_subject['url'])
    Subject.sync(remote_subject) if subject.nil?
    return if subject.nil?

    subject.update_comments
  end

  def has_comments?
     comment_count && comment_count > 0
  end

  def commentable?
    !comment_count.nil?
  end

  def pull_request?
    url.match?(/pull/i)
  end

  def update_status
    if sha.present?
      remote_status = download_status
      if remote_status.present?
        self.status = assign_status(remote_status)
        self.save if changed?
      end
    end
  end

  def reaction_counts
    ReactionSummary.valid_counts(reactions)
  end

  def author_url_path
    if bot_author?
      "/apps/#{BOT_AUTHOR_REGEX.match(author)[1]}"
    else
      "/#{author}"
    end
  end

  def update_comments
    client = github_client
    return unless client

    result = download_comments(client)
    sync_issue_comments(result.items) if result.items.any? || result.complete?
    PullRequestReviewSync.new(self, client: client).sync if pull_request?
  end

  # Incremental fetches never see deletions, so issue_comment webhooks apply
  # them (and edits) directly once the payload's repository is trusted.
  def sync_issue_comment_event(remote_comment, action:, repository_github_id:)
    return unless webhook_repository_authorized?(repository_github_id)

    with_lock do
      if action == 'deleted'
        issue_comments_with_id(remote_value(remote_comment, :id)).destroy_all
      else
        sync_issue_comment(remote_comment)
      end
      update_column(:comment_count, comments.count)
    end
  end

  def comment(user, comment_body)
    return if comment_body.nil? || comment_body.empty?
    comment = comments.create(author: user.github_login, body: comment_body)
    CommentWorker.perform_async_if_configured(comment.id, user.id, self.id)
  end

  def comment_on_github(comment, user)
    return if comment.body.empty?

    client = user.comment_client(comment)

    remote_comment = client.post url.gsub('/pulls/', '/issues/') + '/comments', {body: comment.body}
    comment.github_id = remote_comment.id
    comment.author_association = remote_comment.author_association
    comment.created_at = remote_comment.created_at
    comment.save
  end

  def notifiable_fields
    ['state', 'assignees', 'locked', 'sha', 'comment_count', 'draft']
  end

  def push_to_channels
    notifications.includes({:subject => :labels}, :repository, {:user => :individual_subscription_purchase}).find_each(&:push_to_channel) if (saved_changes.keys & pushable_fields).any?
  end

  private

  def pushable_fields
    ['state', 'status', 'body', 'comment_count', 'draft', 'reactions']
  end

  def assign_status(remote_status)
    if remote_status.state == 'pending'
      remote_status.statuses.present? ? remote_status.state : nil
    else
      remote_status.state
    end
  end

  def download_status
    return unless github_client
    github_client.combined_status(repository_full_name, sha)
  rescue Octokit::ClientError
    nil
  end

  #example https://api.github.com/repos/octobox/octobox/issues/1141/comments
  def download_comments(client)
    since = comments.where(activity_kind: 'issue_comment').maximum(:created_at)
    GithubPreviewFetcher.new(client).collection(
      url.gsub('/pulls/', '/issues/') + '/comments',
      params: {since: since}
    )
  end

  def sync_issue_comments(remote_comments)
    with_lock do
      Array(remote_comments).compact.each { |remote_comment| sync_issue_comment(remote_comment) }
      update_column(:comment_count, comments.count)
    end
  end

  def sync_issue_comment(remote_comment)
    comment = issue_comments_with_id(remote_value(remote_comment, :id)).first_or_initialize
    created_at = remote_value(remote_comment, :created_at)
    comment.assign_attributes(
      author: remote_value(remote_comment, :user, :login) || 'ghost',
      url: remote_value(remote_comment, :url),
      html_url: remote_value(remote_comment, :html_url),
      body: remote_value(remote_comment, :body).try(:gsub, "\u0000", ''),
      author_association: remote_value(remote_comment, :author_association),
      created_at: created_at,
      updated_at: remote_value(remote_comment, :updated_at) || created_at,
      activity_kind: 'issue_comment',
      github_node_id: remote_value(remote_comment, :node_id)
    )
    # An absent summary keeps the stored counts; an empty one clears them.
    reaction_counts = ReactionSummary.from(remote_comment)
    comment.reactions = reaction_counts unless reaction_counts.nil?
    comment.save! if comment.changed?
  end

  def issue_comments_with_id(github_id)
    comments.where(github_id: github_id, activity_kind: [nil, 'issue_comment'])
  end

  # Webhook payloads arrive as hashes, API responses as Sawyer resources.
  def remote_value(remote, *keys)
    keys.reduce(remote) { |object, key| object.is_a?(Hash) ? object[key.to_s] : object.try(key) }
  end

  def webhook_repository_authorized?(repository_github_id)
    return false unless repository&.github_id.to_s == repository_github_id.to_s
    return app_installation.present? if repository.private?

    github_client.present?
  end

  def github_client
    return @preferred_github_client if @preferred_github_client

    if app_installation.present?
      app_installation.github_client
    else
      users.with_access_token.first&.github_client
    end
  end

  def extract_full_name_from_remote_subject(remote_subject)
    # webhook payloads don't always have 'repository' info
    if remote_subject['repository']
      remote_subject['repository']['full_name']
    elsif remote_subject['full_name']
      remote_subject['full_name']
    else
      extract_full_name(remote_subject['url'])
    end
  end

  def extract_full_name(url)
    url.match(/\/repos\/([\w.-]+\/[\w.-]+)\//)[1]
  end

  def extract_comment_count_from_remote_subject(remote_subject)
    remote_subject['comments'] || remote_subject.fetch('commit', {})['comment_count']
  end

  def involved_user_ids
    involved_users = users.with_access_token.not_recently_synced.active
    involved_users += repository.users.with_access_token.not_recently_synced.active if repository.present?
    involved_users.uniq.reject(&:syncing?).map(&:id)
  end

  def bot_author?
    BOT_AUTHOR_REGEX.match?(author)
  end
end
