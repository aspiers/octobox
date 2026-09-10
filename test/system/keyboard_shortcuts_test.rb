# frozen_string_literal: true

require 'application_system_test_case'

class KeyboardShortcutsTest < ApplicationSystemTestCase
  setup do
    stub_include_comments
    @user = create(:user, disable_confirmations: true)
    @notification1 = create(:notification, user: @user, subject: create(:subject), subject_title: 'First notification')
    @notification2 = create(:notification, user: @user, subject_title: 'Second notification')
    @notification3 = create(:notification, user: @user, subject_title: 'Third notification')
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

  def send_keys(*keys)
    find('body').send_keys(*keys)
  end
end
