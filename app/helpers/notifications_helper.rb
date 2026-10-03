module NotificationsHelper
  REASON_LABELS = {
    'comment'        => 'primary',
    'author'         => 'success',
    'state_change'   => 'info',
    'mention'        => 'warning',
    'assign'         => 'danger',
    'subscribed'     => 'subscribed',
    'team_mention'   => 'team_mention',
    'security_alert' => 'security_alert'
  }.freeze

  STATE_LABELS = {
    'open'   => 'success',
    'closed' => 'danger',
    'merged' => 'subscribed'
  }

  SUBJECT_TYPES = {
    'RepositoryInvitation'         => 'mail',
    'Issue'                        => 'issue-opened',
    'PullRequest'                  => 'git-pull-request',
    'Commit'                       => 'git-commit',
    'Release'                      => 'tag',
    'Discussion'                   => 'comment-discussion',
    'RepositoryVulnerabilityAlert' => 'alert'
  }.freeze

  SUBJECT_STATUS = {
    success: "success",
    failure: "failure",
    error: "error",
    pending: "pending"
  }

  NOTIFICATION_STATUS_OCTICON = {
    'success' => 'check',
    'failure' => 'x',
    'error' => 'alert',
    'pending' => 'dot-fill'
  }

  COMMENT_STATUS = {
    'APPROVED' => 'success',
    'CHANGES_REQUESTED' => 'error',
    'COMMENTED' => 'pending'
  }

  COMMENT_STATUS_OCTICON = {
    'APPROVED' => 'check',
    'CHANGES_REQUESTED' => 'x',
    'COMMENTED' => 'dot-fill'
  }

  REACTION_ICONS = {
    '+1' => ['👍', 'thumbs up'],
    '-1' => ['👎', 'thumbs down'],
    'laugh' => ['😄', 'laugh'],
    'hooray' => ['🎉', 'hooray'],
    'confused' => ['😕', 'confused'],
    'heart' => ['❤️', 'heart'],
    'rocket' => ['🚀', 'rocket'],
    'eyes' => ['👀', 'eyes']
  }.freeze

  CI_ACTIVITY_OCTICONS = {
    'pending' => 'dot-fill',
    'success' => 'check',
    'failure' => 'x',
    'cancelled' => 'circle-slash',
    'skipped' => 'skip',
    'neutral' => 'dash',
    'action_required' => 'alert'
  }.freeze

  CI_ACTIVITY_TEXT_CLASSES = {
    'pending' => 'text-warning',
    'success' => 'text-success',
    'failure' => 'text-danger',
    'cancelled' => 'text-muted',
    'skipped' => 'text-muted',
    'neutral' => 'text-muted',
    'action_required' => 'text-warning'
  }.freeze

  def filters
    {
      reason:          params[:reason],
      unread:          params[:unread],
      repo:            params[:repo],
      number:          params[:number],
      type:            params[:type],
      archive:         params[:archive],
      starred:         params[:starred],
      owner:           params[:owner],
      per_page:        params[:per_page],
      q:               params[:q],
      state:           params[:state],
      label:           params[:label],
      author:          params[:author],
      bot:             params[:bot],
      unlabelled:      params[:unlabelled],
      assigned:        params[:assigned],
      is_private:      params[:is_private],
      status:          params[:status],
      draft:           params[:draft],
    }
  end

  def inbox_selected?
    !archive_selected? && !starred_selected? && !showing_search_results?
  end

  def archive_selected?
    filters[:archive].present?
  end

  def starred_selected?
    filters[:starred].present?
  end

  def showing_search_results?
    filters[:q].present?
  end

  def show_archive_icon?
    starred_selected? || showing_search_results?
  end

  def notification_param_keys
    filters.keys - [:per_page]
  end

  def bucket_param_keys
    [:archive, :starred]
  end

  def filter_param_keys
    notification_param_keys - bucket_param_keys
  end

  def any_active_filters?
    filter_param_keys.any?{|param| filters[param].present? }
  end

  def filtered_params(override = {})
    filters.merge(override)
  end

  def mute_button
    function_button('Mute', 'mute', "mute", 'Mute notification', false)
  end

  def delete_button
    function_button("Delete", 'trash', "delete", 'Delete notification', false)
  end

  def archive_button
    function_button("Archive", 'checklist', "archive_toggle archive", 'Archive', false)
  end

  def unarchive_button
    function_button("Unarchive", 'inbox', "archive_toggle unarchive", 'Unarchive notification', false)
  end

  def mute_selected_button
    function_button('Mute selected', 'mute', 'mute_selected', 'Mute selected items')
  end

  def mark_read_selected_button
    function_button('Mark as read', 'eye', 'mark_read_selected', 'Mark items as read')
  end

  def archive_selected_button
    function_button("Archive selected", 'checklist', "archive_toggle archive_selected", 'Archive selected items')
  end

  def unarchive_selected_button
    function_button("Unarchive selected", 'inbox', "archive_toggle unarchive_selected", 'Unarchive selected items')
  end

  def delete_selected_button
    function_button("Delete selected", 'trash', "delete_selected", 'Delete selected items')
  end

  def select_all_button(cur_selected, total)
    button_tag(type: 'button', class: "select_all btn btn-sm btn-outline-dark hidden-button", 'data-toggle': "tooltip", 'data-placement': "bottom", 'title': "Number of items selected") do
      octicon('check', height: 16) +
        content_tag(:span, " #{cur_selected}", class: 'bold d-none d-md-inline-block ml-1') +
        " | " +
        content_tag(:span, " #{total}", class: 'd-none d-md-inline-block')
    end if cur_selected < total
  end

  def function_button(title, octicon, css_class, tooltip, hidden=true)
    button_tag(type: 'button', class: "#{css_class} btn btn-sm btn-outline-dark #{'hidden-button' if hidden}", 'data-toggle': "tooltip", 'data-placement': "bottom", 'title': tooltip ) do
      octicon(octicon, height: 16) + content_tag(:span, "#{title}", class: 'd-none d-xl-inline-block ml-1')
    end
  end

  def no_url_filter_parameters_present
    notification_param_keys.all?{|param| params[param].blank? }
  end

  def notification_icon(notification)
    subject_type = notification.subject_type
    state = notification.user.try(:github_app_authorized?) ? notification.state : nil
    return 'issue-closed' if subject_type == 'Issue' && state == 'closed'
    return 'git-merge' if subject_type == 'PullRequest' && state == 'merged'
    return 'git-pull-request-closed' if subject_type == 'PullRequest' && state == 'closed'
    return 'git-pull-request-draft' if subject_type == 'PullRequest' && notification.draft?
    subject_type_icon(subject_type)
  end

  def subject_type_icon(subject_type)
    SUBJECT_TYPES[subject_type]
  end

  def notification_icon_title(notification)
    state = notification.state
    subject_title = notification.subject_type.underscore.humanize
    return "#{state.underscore.humanize} #{subject_title.downcase}" if %w[closed merged].include?(state)
    return "Draft #{subject_title.downcase}" if notification.draft?
    return subject_title if state.blank?

    "#{state.underscore.humanize} #{subject_title.downcase}"
  end

  def notification_icon_color(notification)
    return unless notification.display_subject?

    state = notification.state
    return 'text-subscribed' if state == 'closed' && notification.subject_type == 'Issue'
    return 'text-danger' if state == 'closed'
    return 'text-subscribed' if state == 'merged'
    return 'text-draft' if notification.draft?
    return 'text-success' if state == 'open'
  end

  def reason_label(reason)
    REASON_LABELS.fetch(reason, 'secondary')
  end

  def state_label(state)
    STATE_LABELS.fetch(state, 'secondary')
  end

  def filter_option(param)
    if filters[param].present?
      link_to root_path(filters.except(param)), class: "btn btn-sm btn-outline-dark" do
        concat octicon('x', :height => 16)
        concat ' '
        concat yield
      end
    end
  end

  def reason_filter_option(reason)
    if filters[:reason].present? && reason.present?
      reasons = filters[:reason].split(',').reject(&:empty?)
      index = reasons.index(reason.underscore.downcase)
      reasons.delete_at(index) if index
      link_to root_path(filters.merge(:reason => reasons.join(','))), class: "btn btn-sm btn-outline-dark" do
        concat octicon('x', :height => 16)
        concat ' '
        concat yield
      end
    end
  end

  def filter_link(param, value, count)
    sidebar_filter_link(active: params[param] == value.to_s, param: param, value: value, count: count) do
      yield
    end
  end

  def org_filter_link(param, value)
    sidebar_filter_link(active: params[param] == value.to_s, param: param, value: value, except: :repo, link_class: 'owner-label') do
      yield
    end
  end

  def repo_filter_link(param, repo_name, count)
    active = params[param] == repo_name || params[:owner] == repo_name.split('/')[0]
    sidebar_filter_link(active: active, param: param, value: repo_name, count: count, except: :owner, link_class: 'repo-label', title: repo_name) do
      yield
    end
  end

  def sidebar_filter_link(active:, param:, value:, count: nil, except: nil, link_class: nil, path_params: nil, title: nil)
    css_class = 'nav-item'
    css_class += ' active' if active
    css_class += " #{param}-#{value}"

    content_tag :li, class: css_class, title: title do
      active = (active && not_repo_in_active_org(param))
      path_params ||= filtered_params(param => (active ? nil : value)).except(except)
      link_to root_path(path_params), class: (active ? "nav-link active filter #{link_class}" : "nav-link filter #{link_class}") do
        yield
        if active && not_repo_in_active_org(param)
          concat content_tag(:span, octicon('x', :height => 16), class: 'badge badge-light')
        elsif count.present?
          concat content_tag(:span, count, class: 'badge badge-light')
        end
      end
    end
  end

  def reason_filter_link(value, count)
    active = params[:reason].present? && params[:reason].split(',').include?(value.to_s)
    link_value = reason_link_param_value(params[:reason], value, active)
    path_params = filtered_params(:reason => link_value)

    sidebar_filter_link(active: active, param: :reason, value: link_value, count: count, path_params: path_params) do
      yield
    end
  end

  def reason_link_param_value(param, value, active)
    reasons = param.try(:split, ',') || []
    active ? reasons.delete(value) : reasons.push(value)
    reasons.try(:join, ',')
  end

  def not_repo_in_active_org(param)
    return true unless param == :repo
    params[:owner].blank?
  end

  def search_query_matches?(query, other_query)
    query = Search.new(query: query, scope: {}).to_query
    other_query = Search.new(query: other_query, scope: {}).to_query
    query.split(' ').sort == other_query.split(' ').sort
  end

  def search_pinned?(query)
    return unless query.present?
    return false if current_user.pinned_searches.empty?

    current_user.pinned_searches.any? do |pinned_search|
      search_query_matches?(query, pinned_search.query)
    end
  end

  def notification_status(status)
    return unless status.present?
    content_tag(:span,
      octicon(NOTIFICATION_STATUS_OCTICON[status], height: 24, class: status),
      class: "badge badge-light badge-pr #{status}",
      title: status.humanize,
      data: {toggle: 'tooltip'}
    )
  end

  def comment_status(status)
    return unless status.present?
    css_class = COMMENT_STATUS.fetch(status, 'secondary')
    content_tag(:span,
      octicon(COMMENT_STATUS_OCTICON.fetch(status, 'dot-fill'), height: 24, class: css_class),
      class: "badge badge-light #{css_class}",
      title: status.humanize,
      data: {toggle: 'tooltip'}
    )
  end

  def review_state_text(status)
    {
      'APPROVED' => 'approved these changes',
      'CHANGES_REQUESTED' => 'requested changes',
      'COMMENTED' => 'reviewed'
    }.fetch(status, "submitted a #{status.to_s.humanize.downcase}")
  end

  def review_location(context)
    path = context['path'] || 'Unknown file'
    current_line = context['line']
    original_line = context['original_line']
    start_line = context['start_line'] || context['original_start_line']
    line = current_line || original_line
    return "#{path} (file comment)" unless line

    range = start_line && start_line != line ? "#{start_line}-#{line}" : line.to_s
    qualifier = current_line ? 'line' : 'original line'
    "#{path} (#{qualifier} #{range})"
  end

  def safe_markdown(body)
    sanitize(parse_markdown(body))
  end

  def reaction_chips(reactable)
    chips = reactable.reaction_counts.filter_map do |content, count|
      icon, name = REACTION_ICONS[content]
      next unless icon

      accessible_name = "#{name}: #{pluralize(count, 'reaction')}"
      content_tag(:span, class: 'reaction-chip', title: "#{name}: #{count}",
                         aria: {label: accessible_name}) do
        safe_join([
          content_tag(:span, accessible_name, class: 'sr-only'),
          content_tag(:span, icon, aria: {hidden: true}),
          content_tag(:span, count, class: 'reaction-count', aria: {hidden: true})
        ])
      end
    end
    return if chips.empty?

    content_tag(:div, safe_join(chips), class: 'reaction-chips mt-2', role: 'group',
                                             aria: {label: 'Reactions'})
  end

  def ci_activity_icon(activity)
    CI_ACTIVITY_OCTICONS.fetch(activity.outcome)
  end

  def ci_activity_text_class(activity)
    CI_ACTIVITY_TEXT_CLASSES.fetch(activity.outcome)
  end

  def sidebar_notification_status(status)
    octicon(NOTIFICATION_STATUS_OCTICON[status], height: 24, class: "sidebar-icon #{status}")
  end

  def subject_with_number(notification)
    if ['Issue', 'PullRequest', 'Discussion'].include?(notification.subject_type)
      capture do
        concat content_tag(:span, "##{notification.subject_number}", class: "notification-number")
        concat " "
        concat notification.subject_title
      end
    else
      notification.subject_title
    end
  end

  def notification_button(subject_type, state = nil)
    return 'issue-closed' if subject_type == 'Issue' && state == 'closed'
    SUBJECT_TYPES[subject_type]
  end

  def notification_button_title(notification)
    state = notification.state
    return state.underscore.humanize if %w[closed merged].include?(state)
    return 'Draft' if notification.draft?
    return notification.subject_type.underscore.humanize if state.blank?

    state.underscore.humanize
  end

  def notification_button_color(notification)
    return unless notification.display_subject?

    state = notification.state
    return 'btn-closed-pr' if notification.subject_type == 'PullRequest' && state == 'closed'
    return 'btn-merged' if state == 'merged'
    return 'btn-draft' if notification.draft?

    {
      'open' => 'btn-open',
      'closed' => 'btn-closed'
    }[state]
  end

  def parse_markdown(str)
    return if str.blank?
    Commonmarker.to_html(str, options: {
      render: { github_pre_lang: true },
      extension: {
        tagfilter: true,
        autolink: true,
        table: true,
        strikethrough: true
      }
    })
  end

  def notification_link(notification)
    notification.display_thread? ? notification_path(notification, filtered_params) : notification.web_url
  end

  def display_thread?
    Octobox.include_comments? && current_user.display_comments
  end

  GITHUB_LOGIN_PATTERN = /\A[A-Za-z0-9](?:[A-Za-z0-9-]{0,37}[A-Za-z0-9])?\z/
  GITHUB_APP_ACTOR_PATTERN = /\A(?<slug>[A-Za-z0-9](?:[A-Za-z0-9-]{0,37}[A-Za-z0-9])?)\[bot\]\z/

  def lifecycle_event_actor(event)
    actor = event.actor_login.presence
    return 'Someone' unless actor
    return lifecycle_actor_link(actor, actor) if actor.match?(GITHUB_LOGIN_PATTERN)

    # Apps act as "<slug>[bot]", which has no user page; GitHub links them to the app listing.
    app = actor.match(GITHUB_APP_ACTOR_PATTERN)
    return actor unless app

    lifecycle_actor_link(actor, "apps/#{app[:slug]}")
  end

  def lifecycle_actor_link(actor, path)
    link_to actor, "#{Octobox.config.github_domain}/#{path}", class: 'text-muted', target: '_blank', rel: 'noopener'
  end

  # The first preview of a subject renders before its background refresh has
  # produced a snapshot; the client polls while this holds.
  def lifecycle_events_pending?(snapshot)
    snapshot.nil? || snapshot.status == 'refreshing'
  end

  def lifecycle_event_commit_link(event, sha = event.commit_sha)
    return unless sha&.match?(/\A[0-9a-f]{7,64}\z/i)

    repository = event.lifecycle_event_snapshot.subject.repository_full_name
    return unless repository&.match?(/\A[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+\z/)

    link_to sha.first(7), "#{Octobox.config.github_domain}/#{repository}/commit/#{sha}",
            target: '_blank', rel: 'noopener'
  end

  def lifecycle_event_native_url(event)
    subject_url = event.lifecycle_event_snapshot.subject.html_url
    return unless subject_url&.start_with?("#{Octobox.config.github_domain}/")

    event.github_event_id ? "#{subject_url}#event-#{event.github_event_id}" : subject_url
  end

  def metadata_event_actor(event)
    actor = event.actor_login.presence || 'Someone'
    return actor unless actor.match?(/\A[A-Za-z0-9](?:[A-Za-z0-9-]{0,37}[A-Za-z0-9])?\z/)

    link_to actor, "#{Octobox.config.github_domain}/#{actor}",
            class: 'text-muted', target: '_blank', rel: 'noopener'
  end

  def metadata_event_safe_url(url)
    uri = URI.parse(url.to_s)
    github_uri = URI.parse(Octobox.config.github_domain)
    return unless %w[http https].include?(uri.scheme)
    return unless uri.scheme == github_uri.scheme && uri.host == github_uri.host &&
                  uri.port == github_uri.port && uri.userinfo.nil?

    uri.to_s
  rescue URI::InvalidURIError
    nil
  end

  def metadata_event_source_label(event)
    source = event.source_context
    repository = source['repository_full_name']
    number = source['number']
    return "#{repository}##{number}" if repository.present? && number.present?

    source['title'].presence || 'another issue or pull request'
  end
end
