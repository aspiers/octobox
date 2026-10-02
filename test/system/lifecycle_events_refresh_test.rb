# frozen_string_literal: true

require 'application_system_test_case'

class LifecycleEventsRefreshSystemTest < ApplicationSystemTestCase
  setup do
    Octobox.config.stubs(:background_jobs_enabled).returns(true)
    Octobox.config.stubs(:include_comments).returns(true)
    @user = create(:user)
    repository = create(:repository, full_name: 'octobox/octobox', private: false)
    @subject = create(:subject, repository: repository, comment_count: nil)
    @notification = create(:notification, user: @user, subject_url: @subject.url,
                           repository_full_name: repository.full_name, subject_type: 'Issue')
    sign_in_as(@user)
  end

  test 'a first view fills in lifecycle activity once the background refresh completes' do
    find("#notification-#{@notification.id} .thread-link").click

    assert_selector '.lifecycle-events[data-refresh-pending]', text: 'Checking GitHub for activity'
    assert_no_selector '.lifecycle-event'

    # Simulate the background worker finishing after the first render.
    snapshot = create(:lifecycle_event_snapshot, subject: @subject)
    create(:lifecycle_event, lifecycle_event_snapshot: snapshot, actor_login: 'linear-code[bot]',
           state_reason: 'not_planned')

    assert_selector '.lifecycle-event[data-event-type="closed"]',
                    text: /linear-code\[bot\]\s+closed this issue\s+as not planned/, wait: 10
    assert_no_selector '.lifecycle-events[data-refresh-pending]'
    assert_no_text 'Checking GitHub for activity'
  end

  test 'background completion interleaves new activity with comments without reloading' do
    @subject.update!(comment_count: 2)
    start = Time.utc(2026, 1, 1)
    earlier = create(:comment, subject: @subject, created_at: start)
    later = create(:comment, subject: @subject, created_at: start + 2.minutes)
    find("#notification-#{@notification.id} .thread-link").click
    assert_selector '.lifecycle-events[data-refresh-pending]'
    assert_selector "#comment-#{earlier.id}"
    assert_selector "#comment-#{later.id}"

    snapshot = create(:lifecycle_event_snapshot, subject: @subject)
    create(:lifecycle_event, lifecycle_event_snapshot: snapshot, event_type: 'merged',
           github_identity: 'github:async-merge', occurred_at: start + 1.minute)

    assert_selector '.lifecycle-event[data-event-identity="github:async-merge"]', wait: 10
    assert_equal ["comment-#{earlier.id}", 'github:async-merge', "comment-#{later.id}"], conversation_identities
    assert_no_selector '.lifecycle-events[data-refresh-pending]'
  end

  test 'background completion preserves an expanded mixed conversation' do
    @subject.update!(comment_count: 6)
    start = Time.utc(2026, 1, 1)
    comments = 6.times.map { |index| create(:comment, subject: @subject, created_at: start + index.minutes) }
    visit expand_comments_notification_path(@notification)
    assert_selector '.lifecycle-events[data-refresh-pending]'
    assert_selector '.notification-conversation .card-comment', count: 6

    snapshot = create(:lifecycle_event_snapshot, subject: @subject)
    create(:lifecycle_event, lifecycle_event_snapshot: snapshot,
           github_identity: 'github:expanded-refresh', occurred_at: start + 30.seconds)

    assert_selector '.lifecycle-event[data-event-identity="github:expanded-refresh"]', wait: 10
    expected = comments.map { |comment| "comment-#{comment.id}" }
    expected.insert(1, 'github:expanded-refresh')
    assert_equal expected, conversation_identities
    assert_no_selector '#more-comments'
  end

  test 'a live comment arriving during polling appears once in chronological position' do
    @subject.update!(comment_count: 1)
    start = Time.utc(2026, 1, 1)
    earlier = create(:comment, subject: @subject, created_at: start)
    find("#notification-#{@notification.id} .thread-link").click
    assert_selector '.lifecycle-events[data-refresh-pending]'

    later = create(:comment, subject: @subject, created_at: start + 2.minutes)
    @subject.update!(comment_count: 2)
    html = ApplicationController.render(partial: 'notifications/issue_comment', locals: { comment: later })
    page.execute_script <<~JS
      var originalCreate = App.cable.subscriptions.create;
      App.cable.subscriptions.create = function(_options, callbacks) {
        callbacks.received(#{ {subject_id: @subject.id, comment_id: later.id, comment_html: html}.to_json });
        return { unsubscribe: function() {} };
      };
      subscribeToComments();
      App.cable.subscriptions.create = originalCreate;
    JS
    assert_selector "#comment-#{later.id}", count: 1

    snapshot = create(:lifecycle_event_snapshot, subject: @subject)
    create(:lifecycle_event, lifecycle_event_snapshot: snapshot, event_type: 'merged',
           github_identity: 'github:live-merge', occurred_at: start + 1.minute)
    assert_selector '.lifecycle-event[data-event-identity="github:live-merge"]', wait: 10
    assert_selector "#comment-#{later.id}", count: 1
    assert_equal ["comment-#{earlier.id}", 'github:live-merge', "comment-#{later.id}"], conversation_identities
  end

  test 'refresh retains collapsed state and selected focused comment while accepting body edits' do
    install_state_refresh
    page.execute_script <<~JS
      var entry = document.getElementById('comment-123');
      entry.classList.add('js-current-preview-entry');
      entry.setAttribute('tabindex', '-1');
      entry.focus();
    JS
    assert_selector '.notification-conversation[data-refreshed]', wait: 10
    assert_selector '#comment-123 .collapse:not(.show)', visible: :all
    assert_selector '#comment-123 [aria-expanded="false"].collapsed', visible: :all
    assert_selector '#comment-123.js-current-preview-entry'
    assert_equal 'comment-123', page.evaluate_script('document.activeElement.id')
    assert_selector '#comment-123 .card-body', text: 'Edited incoming body', visible: :all
  end

  test 'refresh retains selected review without stealing focus from the reply' do
    install_state_refresh(selected: 'review-456')
    page.execute_script "document.getElementById('comment_body').focus()"
    assert_selector '.notification-conversation[data-refreshed]', wait: 10
    assert_selector '#review-456.js-current-preview-entry'
    assert_equal 'comment_body', page.evaluate_script('document.activeElement.id')
  end

  test 'refresh retains selected focused lifecycle identity without an element id' do
    install_state_refresh(selected: 'event')
    assert_selector '.notification-conversation[data-refreshed]', wait: 10
    assert_selector '[data-event-identity="github:state-event"].js-current-preview-entry'
    assert_equal 'github:state-event', page.evaluate_script('document.activeElement.dataset.eventIdentity')
  end

  test 'refresh retains selected focused review threads and activity' do
    %w[review-thread-789 review-activity-987].each do |identity|
      install_state_refresh(selected: identity)
      assert_selector '.notification-conversation[data-refreshed]', wait: 10
      assert_selector "##{identity}.js-current-preview-entry"
      assert_equal identity, page.evaluate_script('document.activeElement.id')
    end
  end

  test 'refresh does not transfer selection or focus to a different entry' do
    install_state_refresh(selected: 'review-456', remove_selected: true)
    assert_selector '.notification-conversation[data-refreshed]', wait: 10
    assert_no_selector '.js-current-preview-entry'
    assert_equal 'BODY', page.evaluate_script('document.activeElement.tagName')
  end

  private

  # Use a controlled polling response to exercise Bootstrap and optional keyboard
  # markers even on this source branch, which does not include navigation.
  def install_state_refresh(selected: nil, remove_selected: false)
    html = <<~HTML
      <div class="notification-conversation">
        <section data-preview-section="lifecycle" data-refresh-pending data-refresh-url="/state-refresh"></section>
        <div id="comment-123" class="card-comment">
          <div class="card-header collapsed" data-toggle="collapse" data-target=".comment-123" aria-expanded="false"></div>
          <div class="comment-123 card-body collapse">Original body</div>
        </div>
        <div id="review-456" class="card-comment">Review</div>
        <div id="review-thread-789" class="review-thread">Review thread</div>
        <div id="review-activity-987" class="review-activity">Review request</div>
        <div data-preview-entry data-event-identity="github:state-event">Event</div>
      </div>
    HTML
    incoming = html.sub('Original body', 'Edited incoming body')
                   .sub('data-refresh-pending', 'data-refreshed-section')
                   .sub('notification-conversation"', 'notification-conversation" data-refreshed')
                   .sub('card-header collapsed', 'card-header')
                   .sub('aria-expanded="false"', 'aria-expanded="true"')
                   .sub('card-body collapse', 'card-body collapse show')
    incoming = incoming.sub('<div id="review-456" class="card-comment">Review</div>', '') if remove_selected
    page.execute_script <<~JS
      document.querySelector('.flex-main').classList.add('show-thread');
      document.getElementById('thread').classList.remove('d-none');
      document.getElementById('thread').innerHTML = '<div class="discussion-thread">' + #{html.to_json} + '</div><textarea id="comment_body"></textarea>';
      var originalFetch = window.fetch;
      window.fetch = function(url, options) {
        if (url === '/state-refresh') {
          return Promise.resolve({ok: true, text: function() { return Promise.resolve(#{incoming.to_json}); }});
        }
        return originalFetch(url, options);
      };
      var selected = #{selected.to_json};
      if (selected) {
        var entry = selected === 'event' ? document.querySelector('[data-event-identity]') : document.getElementById(selected);
        entry.classList.add('js-current-preview-entry');
        entry.setAttribute('tabindex', '-1');
        entry.focus();
      }
      Octobox.initialize();
    JS
  end

  def conversation_identities
    all('.notification-conversation .card-comment[id], .notification-conversation .lifecycle-event').map do |node|
      node[:id].presence || node['data-event-identity']
    end
  end
end
