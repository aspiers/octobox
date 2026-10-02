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

  test 'a completed response generated before a persisted live comment is discarded and refetched' do
    assert_delayed_comment_survives(:channel)
  end

  test 'a completed response generated before a posted comment insertion is discarded and refetched' do
    assert_delayed_comment_survives(:append)
  end

  test 'content edits during an outstanding request reject stale data without copying old bodies' do
    install_state_refresh(delay: true)
    assert_selector 'body[data-state-response-ready]', wait: 10
    page.execute_script <<~JS
      document.querySelector('#comment-123 .card-body').firstChild.textContent = 'Local body edit';
      window.releaseStateRefresh();
    JS
    assert_selector '.notification-conversation[data-refreshed]', wait: 10
    assert_selector '#comment-123 .card-body', text: 'Edited incoming body', visible: :all
    assert_equal 2, page.evaluate_script('window.statePollCount')
  end

  test 'selection and collapse changes during an outstanding request do not invalidate it' do
    install_state_refresh(delay: true)
    assert_selector 'body[data-state-response-ready]', wait: 10
    page.execute_script <<~JS
      var entry = document.getElementById('comment-123');
      entry.classList.add('js-current-preview-entry');
      entry.setAttribute('tabindex', '-1');
      entry.focus();
      entry.querySelector('.card-body').classList.add('show');
      entry.querySelector('.card-header').classList.remove('collapsed');
      entry.querySelector('.card-header').setAttribute('aria-expanded', 'true');
      window.releaseStateRefresh();
    JS
    assert_selector '.notification-conversation[data-refreshed]', wait: 10
    assert_selector '#comment-123.js-current-preview-entry .collapse.show'
    assert_equal 'comment-123', page.evaluate_script('document.activeElement.id')
    assert_equal 1, page.evaluate_script('window.statePollCount')
  end

  test 'failed requests and successful replacements leave no active conversation observers' do
    page.execute_script <<~JS
      var NativeMutationObserver = window.MutationObserver;
      window.activeConversationObservers = 0;
      window.MutationObserver = function(callback) {
        var observer = new NativeMutationObserver(callback);
        var observe = observer.observe.bind(observer);
        var disconnect = observer.disconnect.bind(observer);
        var watching = false;
        observer.observe = function(target, options) {
          if (target.matches && target.matches('.notification-conversation') && !watching) {
            watching = true;
            window.activeConversationObservers += 1;
          }
          observe(target, options);
        };
        observer.disconnect = function() {
          if (watching) window.activeConversationObservers -= 1;
          watching = false;
          disconnect();
        };
        return observer;
      };
    JS
    install_state_refresh(fail_first: true)
    assert_selector '.notification-conversation[data-refreshed]', wait: 10
    assert_equal 2, page.evaluate_script('window.statePollCount')
    assert_equal 0, page.evaluate_script('window.activeConversationObservers')
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

  def assert_delayed_comment_survives(insertion)
    @subject.update!(comment_count: 1)
    start = Time.utc(2026, 1, 1)
    earlier = create(:comment, subject: @subject, created_at: start)
    find("#notification-#{@notification.id} .thread-link").click
    assert_selector '.lifecycle-events[data-refresh-pending]'
    page.execute_script <<~JS
      var originalFetch = window.fetch;
      if (App.comments) App.comments.unsubscribe();
      window.previewPollCount = 0;
      var refreshUrl = document.querySelector('[data-refresh-url]').dataset.refreshUrl;
      window.fetch = function(url, options) {
        if (url !== refreshUrl) return originalFetch(url, options);
        window.previewPollCount += 1;
        if (window.previewPollCount > 1) return originalFetch(url, options);
        return originalFetch(url, options).then(function(response) {
          return response.text().then(function(html) {
            return new Promise(function(resolve) {
              window.releaseStalePreview = function() {
                resolve({ok: response.ok, text: function() { return Promise.resolve(html); }});
              };
              document.body.dataset.stalePreviewReady = 'true';
            });
          });
        });
      };
    JS
    snapshot = create(:lifecycle_event_snapshot, subject: @subject)
    create(:lifecycle_event, lifecycle_event_snapshot: snapshot, event_type: 'merged',
           github_identity: 'github:delayed-merge', occurred_at: start + 1.minute)
    assert_selector 'body[data-stale-preview-ready]', wait: 10

    later = create(:comment, subject: @subject, created_at: start + 2.minutes)
    @subject.update!(comment_count: 2)
    html = ApplicationController.render(partial: 'notifications/issue_comment', locals: { comment: later })
    if insertion == :channel
      page.execute_script <<~JS
        var originalCreate = App.cable.subscriptions.create;
        App.cable.subscriptions.create = function(_options, callbacks) {
          callbacks.received(#{ {subject_id: @subject.id, comment_id: later.id, comment_html: html}.to_json });
          return { unsubscribe: function() {} };
        };
        subscribeToComments();
        App.cable.subscriptions.create = originalCreate;
      JS
    elsif ENV['PREVIEW_REPLY_INSERTION'] == 'ajax'
      # The combined build has the independent reply handler. Exercise it there.
      page.execute_script <<~JS
        if (!document.getElementById('reply')) {
          document.getElementById('thread').insertAdjacentHTML('beforeend', '<form id="reply"><textarea id="comment_body"></textarea></form>');
        }
        $('#reply').trigger('ajax:success', [#{html.to_json}]);
      JS
    else
      # The source has no reply handler dependency; exercise its append contract.
      page.execute_script <<~JS
        var comment = new DOMParser().parseFromString(#{html.to_json}, 'text/html').body.firstElementChild;
        document.querySelector('.notification-conversation').append(comment);
      JS
    end
    assert_selector ".notification-conversation #comment-#{later.id}", count: 1
    page.execute_script 'window.releaseStalePreview()'
    assert_selector '.lifecycle-event[data-event-identity="github:delayed-merge"]', wait: 10
    assert_selector ".notification-conversation #comment-#{later.id}", count: 1
    assert_equal ["comment-#{earlier.id}", 'github:delayed-merge', "comment-#{later.id}"], conversation_identities
    assert_operator page.evaluate_script('window.previewPollCount'), :>=, 2
    assert_no_selector '.lifecycle-events[data-refresh-pending]'
  end

  # Enter through the normal thread fetch path, not global initialization, which
  # may autoload a different thread in the combined navigation build.
  def install_state_refresh(selected: nil, remove_selected: false, delay: false, fail_first: false)
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
      var originalFetch = window.fetch;
      window.statePollCount = 0;
      delete document.body.dataset.stateResponseReady;
      window.fetch = function(url, options) {
        if (url === '/state-fixture') {
          return Promise.resolve({ok: true, headers: {get: function() { return 'text/html'; }}, text: function() {
            return Promise.resolve('<div class="discussion-thread">' + #{html.to_json} + '</div><textarea id="comment_body"></textarea>');
          }});
        }
        if (url === '/state-refresh') {
          window.statePollCount += 1;
          if (#{fail_first} && window.statePollCount === 1) return Promise.resolve({ok: false});
          var response = {ok: true, text: function() { return Promise.resolve(#{incoming.to_json}); }};
          if (#{delay} && window.statePollCount === 1) {
            return new Promise(function(resolve) {
              window.releaseStateRefresh = function() { resolve(response); };
              document.body.dataset.stateResponseReady = 'true';
            });
          }
          return Promise.resolve(response);
        }
        return originalFetch(url, options);
      };
      var link = document.createElement('a');
      link.className = 'thread-link';
      link.href = '/state-fixture';
      Octobox.viewThread({preventDefault: function() {}, target: link});
    JS
    assert_selector '#comment-123'
    page.execute_script <<~JS
      var selected = #{selected.to_json};
      if (selected) {
        var entry = selected === 'event' ? document.querySelector('[data-event-identity]') : document.getElementById(selected);
        entry.classList.add('js-current-preview-entry');
        entry.setAttribute('tabindex', '-1');
        entry.focus();
      }
    JS
  end

  def conversation_identities
    all('.notification-conversation .card-comment[id], .notification-conversation .lifecycle-event').map do |node|
      node[:id].presence || node['data-event-identity']
    end
  end
end
