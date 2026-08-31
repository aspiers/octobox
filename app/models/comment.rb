class Comment < ApplicationRecord
  belongs_to :subject

  after_save :push_if_changed

  BOT_AUTHOR_REGEX = /\A(.*)\[bot\]\z/.freeze

  def web_url
    return html_url if native_html_url?

    anchor = case activity_kind
    when 'pull_request_review'
      "pullrequestreview-#{github_id}"
    when 'pull_request_review_comment'
      "discussion_r#{github_id}"
    else
      "issuecomment-#{github_id}"
    end
    "#{subject.html_url}##{anchor}"
  end

  def issue_comment?
    activity_kind.blank? || activity_kind == 'issue_comment'
  end

  def review_submission?
    activity_kind == 'pull_request_review'
  end

  def review_comment?
    activity_kind == 'pull_request_review_comment'
  end

  def review_activity?
    %w[review_requested review_request_removed review_dismissed].include?(activity_kind)
  end

  def review_context
    self[:review_context] || {}
  end

  def author_url_path
    if bot_author?
      "/apps/#{BOT_AUTHOR_REGEX.match(author)[1]}"
    else
      "/#{author}"
    end
  end

  def bot_author?
    BOT_AUTHOR_REGEX.match?(author)
  end

  def unread?(notification)
    notification.last_read_at && DateTime.parse(notification.last_read_at) < created_at
  end

  def push_if_changed
    push_to_channels if (saved_changes.keys & pushable_fields).any?
  end

  def push_to_channels
    return unless issue_comment?

    comment_html = ApplicationController.render(partial: 'notifications/comment', locals: {subject: self.subject.id, comment: self, comments:1})
    ActionCable.server.broadcast "comments:#{subject.id}", {comment_id: self.id, comment_html: comment_html, subject_id: self.subject.id}
  end

  private

  def native_html_url?
    uri = URI.parse(html_url.to_s)
    %w[http https].include?(uri.scheme) && uri.host.present?
  rescue URI::InvalidURIError
    false
  end

  def pushable_fields
    ['body', 'github_id']
  end

end
