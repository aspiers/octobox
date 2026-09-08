# frozen_string_literal: true

require 'application_system_test_case'

class KeyboardShortcutsTest < ApplicationSystemTestCase
  setup do
    stub_include_comments
    @user = create(:user, disable_confirmations: true)
    @notification1 = create(:notification, user: @user, subject: create(:subject), subject_title: 'First notification')
    @notification2 = create(:notification, user: @user, subject: create(:subject), subject_title: 'Second notification')
    @notification3 = create(:notification, user: @user, subject: create(:subject), subject_title: 'Third notification')
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
