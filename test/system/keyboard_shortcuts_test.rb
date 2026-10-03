# frozen_string_literal: true

require 'application_system_test_case'

class KeyboardShortcutsTest < ApplicationSystemTestCase
  setup do
    stub_include_comments
    @user = create(:user, disable_confirmations: true)
    @notification1 = create(:notification, user: @user, subject: create(:subject), subject_title: 'First notification')
    @notification2 = create(:notification, user: @user, subject: create(:subject), subject_title: 'Second notification')
    @notification3 = create(:notification, user: @user, subject_title: 'Third notification')
    @notification1 = create_previewable_notification('First notification')
    @notification2 = create_previewable_notification('Second notification')
    @notification3 = create_previewable_notification('Third notification')
    sign_in_as(@user)
  end

  test 'j moves cursor down the list' do
    assert_selector 'td.js-current'
    initial_row = find('td.js-current').ancestor('tr')

    send_keys 'j'
    sleep 0.1

    new_current = find('td.js-current').ancestor('tr')
    refute_equal initial_row[:id], new_current[:id]
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

  def send_keys(*keys)
    find('body').send_keys(*keys)
  end
end
