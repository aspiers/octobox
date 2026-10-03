# frozen_string_literal: true

require 'application_system_test_case'

class KeyboardShortcutsTest < ApplicationSystemTestCase
  setup do
    stub_include_comments
    @user = create(:user, disable_confirmations: true)
    @notification1 = create_previewable_notification('First notification')
    @notification2 = create_previewable_notification('Second notification')
    @notification3 = create_previewable_notification('Third notification')
    page.current_window.resize_to(1400, 900)
    sign_in_as(@user)
  end

  test 'previews the selected notification on page load' do
    show_preview_pane

    assert_preview_matches_current_row
  end

  test 'keeps a directly requested notification selected and previewed' do
    page.current_window.resize_to(2400, 900)
    visit "/notifications/#{@notification2.id}"

    assert_equal "notification-#{@notification2.id}", find('td.js-current').ancestor('tr')[:id]
    assert_selector "#notification-thread[data-id='#{@notification2.id}']"
    assert_current_path "/notifications/#{@notification2.id}"
  end

  test 'j moves cursor down the list' do
    assert_selector 'td.js-current'
    initial_row = find('td.js-current').ancestor('tr')

    send_keys 'j'
    sleep 0.1

    new_current = find('td.js-current').ancestor('tr')
    refute_equal initial_row[:id], new_current[:id]
  end

  test 'moving the cursor previews the newly selected notification' do
    show_preview_pane
    initial_row = find('td.js-current').ancestor('tr')

    send_keys 'j'

    assert_preview_matches_current_row
    refute_equal initial_row[:id], find('td.js-current').ancestor('tr')[:id]
  end

  test 'keeps the preview on the latest selection when responses arrive out of order' do
    show_preview_pane
    rows = all('tr.notification')
    delayed_id = rows[1][:id].delete_prefix('notification-')
    page.execute_script(<<~JS)
      var originalFetch = window.fetch;
      window.fetch = function(url, options) {
        var delay = String(url).includes('/notifications/#{delayed_id}') ? 300 : 0;
        return new Promise(function(resolve, reject) {
          setTimeout(function() {
            originalFetch(url, options).then(resolve, reject);
          }, delay);
        });
      };
    JS

    send_keys 'j'
    send_keys 'j'
    sleep 0.5

    assert_preview_matches_current_row
  end

  test 'clicking a row previews that notification' do
    show_preview_pane
    target_row = all('tr.notification')[1]
    page.execute_script("document.querySelector('##{target_row[:id]} td.notification-repo').click()")

    assert_equal target_row[:id], find('td.js-current').ancestor('tr')[:id]
    assert_preview_matches_current_row
  end

  test 'renders preview errors as text' do
    show_preview_pane
    target_row = all('tr.notification')[1]
    error_message = '<img src=x onerror="document.body.dataset.xss=true">'
    page.execute_script(<<~JS)
      var originalFetch = window.fetch;
      window.fetch = function(url, options) {
        if (String(url).includes('/notifications/#{target_row[:id].delete_prefix('notification-')}')) {
          return Promise.resolve(new Response(
            JSON.stringify({ error: #{error_message.to_json} }),
            { headers: { 'content-type': 'application/json' } }
          ));
        }
        return originalFetch(url, options);
      };
      Octobox.markRowCurrent(document.querySelector('##{target_row[:id]}'));
    JS

    assert_text error_message
    assert_no_selector '.header-flash-messages img', visible: :all
    assert_nil page.evaluate_script('document.body.dataset.xss')
  end

  test 'rejects external pagination targets' do
    page.execute_script(<<~JS)
      var item = document.createElement('div');
      item.className = 'page-item next';
      var link = document.createElement('a');
      link.className = 'page-link';
      link.rel = 'next';
      link.href = 'https://example.com/phishing';
      item.appendChild(link);
      document.body.appendChild(item);
    JS

    send_keys 'n'

    assert_current_path '/'
    page.execute_script("document.querySelector('.page-link[rel=next]').href = '/settings'")
    send_keys 'n'
    assert_current_path '/settings', wait: 2
  end

  test 'clicking a row action keeps the current selection and preview' do
    show_preview_pane
    current_row = find('td.js-current').ancestor('tr')
    target_row = all('tr.notification').find { |row| row[:id] != current_row[:id] }

    target_row.find('.toggle-star').click

    assert_equal current_row[:id], find('td.js-current').ancestor('tr')[:id]
    assert_preview_matches_current_row
  end

  test 'archiving previews the next selected notification' do
    show_preview_pane
    archived_row = find('td.js-current').ancestor('tr')

    send_keys 'e'

    assert_no_selector "##{archived_row[:id]}", wait: 5
    assert_preview_matches_current_row
  end

  test 'pointer hover stays hidden after keyboard navigation until the mouse moves' do
    hovered_row = all('tr.notification').last
    hovered_row.hover
    refute_equal 'none', page.evaluate_script("getComputedStyle(document.querySelector('##{hovered_row[:id]}')).boxShadow")

    send_keys 'j'

    table = find('.table-notifications')
    assert_includes table[:class], 'keyboard-navigation-active'
    assert_equal 'none', page.evaluate_script("getComputedStyle(document.querySelector('##{hovered_row[:id]}')).boxShadow")
    selected_row_id = find('td.js-current').ancestor('tr')[:id]

    page.execute_script("document.dispatchEvent(new MouseEvent('mousemove', { bubbles: true }))")

    refute_includes table[:class], 'keyboard-navigation-active'
    refute_equal 'none', page.evaluate_script("getComputedStyle(document.querySelector('##{hovered_row[:id]}')).boxShadow")
    assert_equal selected_row_id, find('td.js-current').ancestor('tr')[:id]
  end

  test 'k moves cursor up the list' do
    send_keys 'j'
    sleep 0.1
    row_after_j = find('td.js-current').ancestor('tr')

    send_keys 'k'
    sleep 0.1

    row_after_k = find('td.js-current').ancestor('tr')
    refute_equal row_after_j[:id], row_after_k[:id]
  end

  test 'question mark opens help modal' do
    assert_no_selector '#help-box.show'

    send_keys :shift, '/'
    assert_selector '#help-box.show', wait: 2
    assert_text 'Keyboard shortcuts'
    assert_text 'Mark done on GitHub; returns on new activity'
    assert_text 'Mark done on GitHub, then open the next notification'
    assert_text 'Remove Octobox copy; GitHub unchanged'
  end

  test 'help modal groups shortcuts in responsive columns' do
    page.current_window.resize_to(1200, 900)
    send_keys :shift, '/'
    assert_selector '#help-box.show', wait: 2

    groups = all('.keyboard-mappings-group')
    assert_equal 4, groups.length
    assert_equal [
      'Navigation',
      'Search and refresh',
      'Notification actions',
      'Preview and general'
    ], groups.map { |group| group.find('h6').text }

    shortcuts = all('[data-shortcut]').map { |row| row['data-shortcut'] }
    assert_operator shortcuts.length, :>=, 14
    assert_equal shortcuts, shortcuts.uniq

    desktop_columns = page.evaluate_script("getComputedStyle(document.querySelector('.keyboard-mappings-grid')).gridTemplateColumns.split(' ').length")
    dialog_width = page.evaluate_script("document.querySelector('.keyboard-help-dialog').getBoundingClientRect().width")
    assert_equal 2, desktop_columns
    assert_operator dialog_width, :>, 800

    page.current_window.resize_to(600, 900)
    mobile_columns = page.evaluate_script("getComputedStyle(document.querySelector('.keyboard-mappings-grid')).gridTemplateColumns.split(' ').length")
    assert_equal 1, mobile_columns
  ensure
    page.current_window.resize_to(1400, 900)
  end

  test 'escape closes help modal' do
    send_keys :shift, '/'
    assert_selector '#help-box.show', wait: 2

    find('#help-box button.close').send_keys(:escape)
    assert_no_selector '#help-box.show', wait: 2
  end

  test 'slash focuses search box and disables shortcuts while typing' do
    send_keys '/'
    assert_equal 'search-box', page.evaluate_script('document.activeElement.id')

    find('#search-box').send_keys 'gi'

    assert_no_selector '#command-palette.show'
    assert_current_path '/'
  end

  test 'g chords navigate directly to fixed sidebar destinations' do
    {
      'a' => /archive=true/,
      's' => /starred=true/,
      'r' => /unread=false/,
      'u' => /unread=true/
    }.each do |key, expected_path|
      visit '/'
      send_keys 'g'
      assert_no_selector '#command-palette.show'
      send_keys key
      assert_current_path expected_path, wait: 2
    end

    send_keys 'g'
    send_keys 'i'
    assert_current_path '/', wait: 2
  end

  test 'unknown and timed-out g chords do not trigger or poison shortcuts' do
    current_row = find('td.js-current').ancestor('tr')
    checkbox = current_row.find('input[type="checkbox"]', visible: :all)

    send_keys 'g'
    send_keys 'x'
    refute checkbox.checked?

    send_keys 'x'
    assert checkbox.checked?
    send_keys 'x'

    send_keys 'g'
    page.execute_script("setTimeout(function() { document.body.dataset.gotoTimeout = 'done'; }, 1100);")
    assert_selector "body[data-goto-timeout='done']", visible: :all, wait: 2
    send_keys 'x'
    assert checkbox.checked?
  end

  test 'command palette ranks prefix matches before other substring matches' do
    page.execute_script(<<~JS)
      var links = document.querySelectorAll('.flex-sidebar a.nav-link');
      links[0].textContent = 'Contains target';
      links[1].textContent = 'Target starts here';
    JS

    send_keys :control, 'k'
    find('#command-palette-input').fill_in with: 'target'

    matches = all('.command-palette-item').map(&:text)
    assert_equal ['Target starts here', 'Contains target'], matches
  end

  test 'control-k opens the command palette and arrow keys change selection' do
    send_keys :control, 'k'
    assert_selector '#command-palette.show', wait: 2

    input = find('#command-palette-input')
    initial_selection = find('.command-palette-item.active').text
    assert_equal 'Inbox', initial_selection
    input.send_keys :down

    refute_equal initial_selection, find('.command-palette-item.active').text
    selected_item = find('.command-palette-item.active')
    selected_item.send_keys :escape
    assert_no_selector '#command-palette.show', wait: 2

    page.execute_script(<<~JS)
      document.body.dispatchEvent(new KeyboardEvent('keydown', {
        key: 'k', metaKey: true, bubbles: true, cancelable: true
      }));
    JS
    assert_selector '#command-palette.show', wait: 2
  end

  test 'command shortcut is not intercepted on pages without the palette' do
    visit '/settings'

    prevented = page.evaluate_script(<<~JS)
      (function() {
        var event = new KeyboardEvent('keydown', {
          key: 'k', ctrlKey: true, bubbles: true, cancelable: true
        });
        document.body.dispatchEvent(event);
        return event.defaultPrevented;
      })()
    JS

    refute prevented
  end

  test 'turbolinks does not cache an open command palette' do
    send_keys :control, 'k'
    assert_selector '#command-palette.show', wait: 2

    page.execute_script("Turbolinks.visit('/settings')")
    assert_current_path '/settings', wait: 2
    page.go_back
    assert_current_path '/', wait: 2

    assert_no_selector '#command-palette.show'
    assert_no_selector '.modal-backdrop'
    refute page.evaluate_script("document.body.classList.contains('modal-open')")
  end

  test 'x toggles checkbox on current row' do
    current_row = find('td.js-current').ancestor('tr')
    checkbox = current_row.find('input[type="checkbox"]', visible: :all)
    refute checkbox.checked?

    send_keys 'x'
    sleep 0.1

    assert checkbox.checked?

    send_keys 'x'
    sleep 0.1

    refute checkbox.checked?
  end

  test 's toggles star on current row' do
    current_row = find('td.js-current').ancestor('tr')
    star = current_row.find('.toggle-star')
    assert_includes star[:class], 'star-inactive'

    send_keys 's'
    sleep 0.3

    star = current_row.find('.toggle-star')
    assert_includes star[:class], 'star-active'
  end

  test 'enter opens current notification on GitHub in a new window and marks it read' do
    current_row = make_current(@notification1)
    github_url = @notification1.web_url
    page.execute_script(<<~JS)
      document.addEventListener('click', function(event) {
        var link = event.target.closest('a[data-octobox-github]');
        if (!link) return;
        event.preventDefault();
        window.lastOpenedLink = { url: link.href, target: link.target, rel: link.rel };
      }, true);
    JS

    send_keys :enter

    opened_link = page.evaluate_script('window.lastOpenedLink')
    assert_equal github_url, opened_link['url']
    assert_equal '_blank', opened_link['target']
    assert_equal 'noopener', opened_link['rel']
    assert_no_selector '.flex-main.show-thread'
    assert_no_selector "##{current_row[:id]}.active"
    sleep 0.3
    refute @notification1.reload.unread
  end

  test 'brackets open the previous and next notifications in the preview' do
    make_current(@notification2)
    send_keys :control, :enter
    assert_selector "#notification-thread[data-id='#{@notification2.id}']", wait: 2

    previous_href = find('#thread a.previous.btn-outline-dark')[:href]
    previous_id = previous_href[%r{/notifications/(\d+)}, 1]

    send_keys '['
    assert_selector "#notification-thread[data-id='#{previous_id}']", wait: 2

    send_keys ']'
    assert_selector "#notification-thread[data-id='#{@notification2.id}']", wait: 2
  end

  test 'c focuses the reply composer in an open preview' do
    Octobox.stubs(:fetch_subject?).returns(true)
    make_current(@notification1)
    send_keys :control, :enter
    assert_selector '#comment_body', wait: 2

    send_keys 'c'

    assert_equal 'comment_body', page.evaluate_script('document.activeElement.id')
  end

  test 'home and end move to the preview boundaries' do
    page.current_window.resize_to(2400, 900)
    make_current(@notification1)
    send_keys :control, :enter
    assert_selector '#notification-thread', wait: 2
    add_preview_spacer

    send_keys :end
    maximum_scroll = page.evaluate_script("document.getElementById('thread').scrollHeight - document.getElementById('thread').clientHeight")
    assert_in_delta maximum_scroll, preview_scroll_top, 2

    send_keys :home
    assert_in_delta 0, preview_scroll_top, 2
  ensure
    page.current_window.resize_to(1400, 900)
  end

  test 'caret and G move to the preview boundaries like home and end' do
    page.current_window.resize_to(2400, 900)
    make_current(@notification1)
    send_keys :enter
    assert_selector '#notification-thread', wait: 2
    add_preview_spacer

    # Sent as shift-chords: Playwright drops a bare 'G' and sends '^' without
    # the shift modifier a real keyboard sets.
    send_keys [:shift, 'g']
    maximum_scroll = page.evaluate_script("document.getElementById('thread').scrollHeight - document.getElementById('thread').clientHeight")
    assert_in_delta maximum_scroll, preview_scroll_top, 2

    send_keys [:shift, '6']
    assert_in_delta 0, preview_scroll_top, 2
  ensure
    page.current_window.resize_to(1400, 900)
  end

  test 'preview scrolling shortcuts move by full and half pages' do
    open_scrollable_preview

    preview_height = page.evaluate_script("document.getElementById('thread').clientHeight")
    preview_scroll_height = page.evaluate_script("document.getElementById('thread').scrollHeight")
    assert_operator preview_scroll_height, :>, preview_height

    send_keys :space
    assert_in_delta preview_height, preview_scroll_top, 2

    set_preview_scroll_top(preview_height * 2)
    send_keys :backspace
    assert_in_delta preview_height, preview_scroll_top, 2

    set_preview_scroll_top(preview_height * 2)
    send_keys 'b'
    assert_in_delta preview_height, preview_scroll_top, 2

    set_preview_scroll_top(0)
    send_keys :shift, :page_down
    assert_in_delta preview_height / 2.0, preview_scroll_top, 2

    set_preview_scroll_top(preview_height * 2)
    send_keys :shift, :page_up
    assert_in_delta preview_height * 1.5, preview_scroll_top, 2
  ensure
    page.current_window.resize_to(1400, 900)
  end

  test 'preview scrolling shortcuts preserve interactive and modified keys' do
    refute shortcut_prevented?(32)
    open_scrollable_preview

    page.execute_script(<<~JS)
      var button = document.createElement('button');
      button.id = 'preview-action';
      button.dataset.clickCount = '0';
      button.addEventListener('click', function() {
        button.dataset.clickCount = String(Number(button.dataset.clickCount) + 1);
      });
      document.getElementById('notification-thread').prepend(button);
    JS

    find('#preview-action').send_keys(:space)
    assert_equal '1', find('#preview-action')['data-click-count']
    assert_in_delta 0, preview_scroll_top, 2

    refute shortcut_prevented?(68, ctrl: true, shift: true)
    refute shortcut_prevented?(68, ctrl: true)
    refute shortcut_prevented?(85, ctrl: true)
    refute shortcut_prevented?(68, meta: true)
    refute shortcut_prevented?(32, alt: true)
    refute shortcut_prevented?(8, alt: true)
    refute shortcut_prevented?(34, shift: true, alt: true)
    refute shortcut_prevented?(191, shift: true, alt: true)
    assert_no_selector '#help-box.show'
    assert_in_delta 0, preview_scroll_top, 2

    page.execute_script("document.getElementById('help-box').classList.add('show')")
    refute shortcut_prevented?(32)
    assert_in_delta 0, preview_scroll_top, 2
  ensure
    page.current_window.resize_to(1400, 900)
  end

  test 'preview scrolling shortcuts ignore nested editable content' do
    open_scrollable_preview
    page.execute_script(<<~JS)
      var editor = document.createElement('div');
      editor.setAttribute('contenteditable', '');
      var child = document.createElement('span');
      child.id = 'editable-child';
      editor.appendChild(child);
      document.getElementById('notification-thread').appendChild(editor);
    JS

    refute shortcut_prevented?(32, target: "document.getElementById('editable-child')")
    assert_in_delta 0, preview_scroll_top, 2
  ensure
    page.current_window.resize_to(1400, 900)
  end

  def open_scrollable_preview
    page.current_window.resize_to(2400, 900)
    make_current(@notification1)
    send_keys :control, :enter
    assert_selector '.flex-main.show-thread', wait: 2
    assert_selector '#notification-thread'

    add_preview_spacer
  end

  def shortcut_prevented?(which, target: 'document.body', ctrl: false, shift: false, alt: false, meta: false)
    page.evaluate_script(<<~JS)
      (() => {
        var event = new KeyboardEvent('keydown', {
          bubbles: true,
          cancelable: true,
          ctrlKey: #{ctrl},
          shiftKey: #{shift},
          altKey: #{alt},
          metaKey: #{meta}
        });
        Object.defineProperty(event, 'which', { value: #{which} });
        #{target}.dispatchEvent(event);
        return event.defaultPrevented;
      })()
    JS
  end

  def make_current(notification)
    page.execute_script("Octobox.markRowCurrent(document.getElementById('notification-#{notification.id}'))")
    find("#notification-#{notification.id}")
  end

  def add_preview_spacer
    page.execute_script(<<~JS)
      var spacer = document.createElement('div');
      spacer.style.height = '5000px';
      document.getElementById('notification-thread').appendChild(spacer);
    JS
  end

  def preview_scroll_top
    page.evaluate_script("document.getElementById('thread').scrollTop")
  end

  def set_preview_scroll_top(value)
    page.execute_script("document.getElementById('thread').scrollTop = #{value}")
  end

  test 'control-enter opens the current notification preview' do
    current_row = make_current(@notification1)
    assert_selector "##{current_row[:id]} a.thread-link"
    assert_no_selector '.flex-main.show-thread'

    send_keys :control, :enter

    assert_selector '.flex-main.show-thread', wait: 2
    assert_selector '#notification-thread'
  end

  test 'command-enter opens the current notification preview' do
    make_current(@notification1)
    page.execute_script(<<~JS)
      var event = new KeyboardEvent('keydown', {
        key: 'Enter', metaKey: true, bubbles: true, cancelable: true
      });
      Object.defineProperty(event, 'which', { value: 13 });
      document.body.dispatchEvent(event);
    JS

    assert_selector '.flex-main.show-thread', wait: 2
    assert_selector '#notification-thread'
  end

  test 'o opens current notification on GitHub in a new window and marks it read' do
    current_row = make_current(@notification1)
    github_url = @notification1.web_url
    page.execute_script(<<~JS)
      document.addEventListener('click', function(event) {
        var link = event.target.closest('a[data-octobox-github]');
        if (!link) return;
        event.preventDefault();
        window.lastOpenedLink = { url: link.href, target: link.target, rel: link.rel };
      }, true);
    JS

    send_keys 'o'

    opened_link = page.evaluate_script('window.lastOpenedLink')
    assert_equal github_url, opened_link['url']
    assert_equal '_blank', opened_link['target']
    assert_equal 'noopener', opened_link['rel']
    assert_no_selector '.flex-main.show-thread'
    assert_no_selector "##{current_row[:id]}.active"
    sleep 0.3
    refute @notification1.reload.unread
  end

  test 'enter preserves focused controls and alt-enter remains unbound' do
    make_current(@notification1)
    page.execute_script(<<~JS)
      var button = document.createElement('button');
      button.id = 'native-control';
      button.addEventListener('click', function() { window.nativeControlActivated = true; });
      document.body.append(button);
      document.addEventListener('click', function(event) {
        if (event.target.closest('a[data-octobox-github]')) window.openedExternalNotification = true;
      }, true);
    JS

    find('#native-control').send_keys(:enter)
    page.execute_script(<<~JS)
      var event = new KeyboardEvent('keydown', {
        key: 'Enter', altKey: true, bubbles: true, cancelable: true
      });
      Object.defineProperty(event, 'which', { value: 13 });
      document.body.dispatchEvent(event);
    JS

    assert page.evaluate_script('window.nativeControlActivated || false')
    refute page.evaluate_script('window.openedExternalNotification || false')
  end

  test 'o ignores unsafe notification URLs' do
    current_row = make_current(@notification1)
    page.execute_script(<<~JS)
      document.getElementById(#{current_row[:id].to_json}).dataset.githubUrl = 'javascript:alert(1)';
      document.addEventListener('click', function(event) {
        if (event.target.closest('a[data-octobox-github]')) window.openedUnsafeLink = true;
      }, true);
    JS

    send_keys 'o'
    sleep 0.3

    refute page.evaluate_script('window.openedUnsafeLink || false')
    assert @notification1.reload.unread
  end

  def create_previewable_notification(title)
    create(:notification, user: @user, subject: create(:subject), subject_title: title)
  end

  test 'control-enter submits a preview comment without losing its position' do
    stub_include_comments
    stub_fetch_subject_enabled
    stub_background_jobs_enabled(value: false)
    Octobox.config.stubs(:push_notifications).returns(false)
    @user.update!(display_comments: true)
    subject = create(:subject, body: 'Issue body', comment_count: 1)
    create(:comment, subject: subject, body: 'Earlier comment')
    @notification1.update!(subject_url: subject.url, unread: false)
    stub_request(:post, "#{subject.url}/comments").to_return do
      sleep 0.2
      {status: 200, body: file_fixture('new_comment.json'), headers: {'Content-Type' => 'application/json'}}
    end
    visit '/'

    find("#notification-#{@notification1.id} .thread-link").click
    assert_selector '#comment_body', wait: 2
    page.execute_script(<<~JS)
      document.querySelector('.discussion-thread').style.minHeight = '2000px';
      var thread = document.getElementById('thread');
      thread.scrollTop = thread.scrollHeight;
    JS
    find('#comment_body').fill_in with: 'Keyboard reply'
    initial_scroll_top = page.evaluate_script("document.getElementById('thread').scrollTop")
    assert_operator initial_scroll_top, :>, 0

    find('#comment_body').send_keys :control, :enter

    assert_selector '.card-comment', text: 'Keyboard reply', wait: 2
    assert_field 'comment_body', with: '', wait: 2
    final_scroll_top = page.evaluate_script("document.getElementById('thread').scrollTop")
    assert_operator final_scroll_top, :>, 0
    assert page.evaluate_script(<<~JS)
      (function() {
        var threadBounds = document.getElementById('thread').getBoundingClientRect();
        var comment = Array.from(document.querySelectorAll('.card-comment')).find(function(element) {
          return element.textContent.includes('Keyboard reply');
        });
        var commentBounds = comment.getBoundingClientRect();
        return commentBounds.top < threadBounds.bottom && commentBounds.bottom > threadBounds.top;
      })()
    JS
    assert_requested :post, "#{subject.url}/comments", times: 1
    assert subject.comments.exists?(body: 'Keyboard reply')
    page.refresh
    assert_selector '.card-comment', text: 'Keyboard reply', visible: :all, wait: 2
  end

  test 'u marks the current notification unread' do
    @notification1.update!(unread: false)
    visit '/'
    current_row = make_current(@notification1)
    assert_no_selector "##{current_row[:id]}.active"

    send_keys 'u'

    assert_selector "##{current_row[:id]}.active", wait: 2
    assert @notification1.reload.unread?
  end

  test 'u is not intercepted while typing' do
    @notification1.update!(unread: false)
    visit '/'
    send_keys '/'
    find('#search-box').send_keys 'u'

    assert_no_selector "#notification-#{@notification1.id}.active"
    refute @notification1.reload.unread?
  end

  def show_preview_pane
    page.current_window.resize_to(2400, 900)
    visit '/'
  end

  def assert_preview_matches_current_row
    current_row = find('td.js-current').ancestor('tr')
    notification_id = current_row[:id].delete_prefix('notification-')
    assert_selector "#notification-thread[data-id='#{notification_id}']", wait: 2
  end

  test 'shift-e archives the current notification and opens the next preview' do
    @notification1.update_column(:updated_at, 3.minutes.ago)
    @notification2.update_column(:updated_at, 2.minutes.ago)
    @notification3.update_column(:updated_at, 1.minute.ago)
    visit '/'

    current_row = make_current(@notification2)
    current_row_id = current_row[:id]
    find("##{current_row_id} a.thread-link").click
    assert_selector "#notification-thread[data-id='#{@notification2.id}']", wait: 2
    assert_equal @notification1.id.to_s, find('#thread a.next.btn-outline-dark')[:href][%r{/notifications/(\d+)}, 1]

    send_keys :shift, 'e'

    assert_selector "#notification-thread[data-id='#{@notification1.id}']", wait: 2
    assert_no_selector "##{current_row_id}"
    assert @notification2.reload.archived?
  end

  test 'shift-y archives and advances the list cursor' do
    current_row = make_current(@notification2)
    current_row_id = current_row[:id]
    next_row_id = page.evaluate_script("document.getElementById('#{current_row_id}').nextElementSibling.id")

    send_keys :shift, 'y'

    assert_no_selector "##{current_row_id}", wait: 2
    assert_equal next_row_id, find('td.js-current').ancestor('tr')[:id]
    assert_no_selector '.flex-main.show-thread'
    assert @notification2.reload.archived?
  end

  test 'archive-and-advance archives all marked notifications' do
    first_row_id = make_current(@notification1)[:id]
    send_keys 'x'
    second_row_id = make_current(@notification2)[:id]
    send_keys 'x'

    send_keys :shift, 'e'

    assert_no_selector "##{first_row_id}", wait: 2
    assert_no_selector "##{second_row_id}"
    assert @notification1.reload.archived?
    assert @notification2.reload.archived?
  end

  test 'n and p route pagination through Turbolinks' do
    create_list(:notification, 50, user: @user)
    visit '/'
    next_url = find('.page-item.next .page-link')[:href]
    capture_turbolinks_visits

    send_keys 'n'
    assert_equal next_url, page.evaluate_script('window.lastTurbolinksVisit')

    visit '/?page=2'
    previous_url = find('.page-item.prev .page-link')[:href]
    capture_turbolinks_visits

    send_keys 'p'
    assert_equal previous_url, page.evaluate_script('window.lastTurbolinksVisit')
  end

  test 'Turbolinks pagination rejects URLs outside Octobox' do
    create_list(:notification, 50, user: @user)
    visit '/'
    capture_turbolinks_visits

    ['https://example.org/', 'javascript:alert(1)'].each do |href|
      page.execute_script("document.querySelector('.page-item.next .page-link').href = #{href.to_json}")

      send_keys 'n'

      assert_nil page.evaluate_script('window.lastTurbolinksVisit')
    end
  end

  test 'r routes foreground sync through Turbolinks' do
    stub_background_jobs_enabled(value: false)
    visit '/'
    sync_url = find('a.js-sync')[:href]
    capture_turbolinks_visits

    send_keys 'r'
    sleep 0.1

    assert_equal sync_url, page.evaluate_script('window.lastTurbolinksVisit')
  end

  def capture_turbolinks_visits
    page.execute_script(<<~JS)
      Turbolinks.visit = function(url) {
        window.lastTurbolinksVisit = new URL(url, window.location.href).href;
      };
    JS
  end

  test 'control-z restores an archive-and-advance action and its cursor' do
    row_id = make_current(@notification2)[:id]
    send_keys :shift, 'y'
    assert_no_selector "##{row_id}", wait: 2
    assert @notification2.reload.archived?

    send_keys :control, 'z'

    assert_selector "##{row_id}", wait: 2
    refute @notification2.reload.archived?
    assert_equal row_id, find('td.js-current').ancestor('tr')[:id]
  end

  test 'control-z restores an archived notification without reloading' do
    row_id = make_current(@notification1)[:id]
    send_keys 'e'
    assert_no_selector "##{row_id}", wait: 2

    send_keys :control, 'z'

    assert_selector "##{row_id}", wait: 2
    refute @notification1.reload.archived?

    within "##{row_id}" do
      find('.notification-checkbox .custom-checkbox').click
      assert find('input[type="checkbox"]', visible: :all).checked?
    end
  end

  test 'undo is discarded after navigating away from the notification list' do
    row_id = make_current(@notification1)[:id]
    send_keys 'e'
    assert_no_selector "##{row_id}", wait: 2

    page.execute_script("Turbolinks.visit('/settings')")
    assert_current_path '/settings', wait: 2
    send_keys :control, 'z'
    assert @notification1.reload.archived?

    page.execute_script("Turbolinks.visit('/')")
    assert_current_path '/', wait: 2
    send_keys :control, 'z'
    assert_no_selector "##{row_id}"
    assert @notification1.reload.archived?
  end

  test 'an in-flight action cannot restore undo state after navigation' do
    row_id = make_current(@notification1)[:id]
    page.execute_script(<<~JS)
      var originalFetch = window.fetch;
      window.fetch = function(url, options) {
        if (!url.includes('/notifications/archive_selected')) return originalFetch(url, options);

        return new Promise(function(resolve, reject) {
          window.releaseArchiveRequest = function() {
            return originalFetch(url, options).then(function(response) {
              resolve(response);
              return response.status;
            }, function(error) {
              reject(error);
              throw error;
            });
          };
        });
      };
    JS

    send_keys 'e'
    page.execute_script("Turbolinks.visit('/settings')")
    assert_current_path '/settings', wait: 2
    archive_result = page.evaluate_async_script(<<~JS)
      var done = arguments[0];
      window.releaseArchiveRequest().then(function(status) {
        done({ status: status });
      }, function(error) {
        done({ error: error.toString() });
      });
    JS
    assert_equal 200, archive_result['status'], archive_result['error']
    assert_current_path '/settings'

    page.execute_script("Turbolinks.visit('/')")
    assert_current_path '/', wait: 2
    send_keys :control, 'z'
    assert_no_selector "##{row_id}"
    assert @notification1.reload.archived?
  end

  test 'control-z restores a muted notification' do
    row_id = make_current(@notification1)[:id]
    send_keys 'm'
    assert_no_selector "##{row_id}", wait: 2

    send_keys :control, 'z'

    assert_selector "##{row_id}", wait: 2
    @notification1.reload
    refute @notification1.archived?
    assert @notification1.unread?
    assert_nil @notification1.muted_at
  end

  test 'command-z restores a deleted notification' do
    row_id = make_current(@notification1)[:id]
    find("##{row_id} a.thread-link").click
    assert_selector '#notification-thread', wait: 2
    page.execute_script('Octobox.deleteThread()')
    assert_no_selector "##{row_id}", wait: 2
    refute Notification.exists?(@notification1.id)

    page.execute_script(<<~JS)
      document.body.dispatchEvent(new KeyboardEvent('keydown', {
        key: 'z', metaKey: true, bubbles: true, cancelable: true
      }));
    JS

    assert_selector "##{row_id}", wait: 2
    assert Notification.exists?(@notification1.id)
  end

  test 'undo preserves native typing and consumes only the latest action' do
    first_row_id = make_current(@notification1)[:id]
    send_keys 'e'
    assert_no_selector "##{first_row_id}", wait: 2

    second_row_id = make_current(@notification2)[:id]
    send_keys 'm'
    assert_no_selector "##{second_row_id}", wait: 2

    send_keys '/'
    find('#search-box').send_keys 'draft'
    find('#search-box').send_keys :control, 'z'
    assert @notification2.reload.muted_at?

    find('#search-box').send_keys :escape
    send_keys :control, 'z'
    assert_selector "##{second_row_id}", wait: 2
    assert @notification1.reload.archived?

    send_keys :control, 'z'
    assert_no_selector "##{first_row_id}"
    assert @notification1.reload.archived?
  end

  def send_keys(*keys)
    find('body').send_keys(*keys)
  end
end
