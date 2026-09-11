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

  test 'slash focuses search box' do
    send_keys '/'
    assert_equal 'search-box', page.evaluate_script('document.activeElement.id')
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
    send_keys :enter
    assert_selector '.flex-main.show-thread', wait: 2
    assert_selector '#notification-thread'

    page.execute_script(<<~JS)
      var spacer = document.createElement('div');
      spacer.style.height = '5000px';
      document.getElementById('notification-thread').appendChild(spacer);
    JS
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

  def preview_scroll_top
    page.evaluate_script("document.getElementById('thread').scrollTop")
  end

  def set_preview_scroll_top(value)
    page.execute_script("document.getElementById('thread').scrollTop = #{value}")
  end

  def create_previewable_notification(title)
    create(:notification, user: @user, subject: create(:subject), subject_title: title)
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

  def send_keys(*keys)
    find('body').send_keys(*keys)
  end
end
