# frozen_string_literal: true

require 'application_system_test_case'

class PaneResizeTest < ApplicationSystemTestCase
  setup do
    stub_include_comments
    @user = create(:user, disable_confirmations: true)
    create(:notification, user: @user, subject_title: 'Fix the widget')
    sign_in_as(@user)
    # Wide enough that the preview pane, and so its divider, are always shown.
    page.current_window.resize_to(1800, 900)
  end

  test 'preview divider is hidden while the preview pane is hidden' do
    page.current_window.resize_to(1400, 900)
    assert_no_selector '.js-thread-divider'
    assert_selector '.js-thread-divider', visible: :hidden
    assert_selector '.js-sidebar-divider'
  end

  test 'dragging the preview divider left widens the preview pane and remembers it' do
    assert_selector '.js-thread-divider'
    before = pane_width('#thread')

    drag_divider_by('.js-thread-divider', -150)

    assert_in_delta before + 150, pane_width('#thread'), 2
    assert_equal pane_width('#thread').round.to_s, stored_width('octobox:thread-width')

    visit current_path
    assert_selector '.js-thread-divider'
    assert_in_delta before + 150, pane_width('#thread'), 2
  end

  test 'dragging the preview divider right narrows the preview pane' do
    assert_selector '.js-thread-divider'
    before = pane_width('#thread')

    drag_divider_by('.js-thread-divider', 120)

    assert_in_delta before - 120, pane_width('#thread'), 2
  end

  test 'the preview pane cannot be dragged narrower than the minimum' do
    assert_selector '.js-thread-divider'

    drag_divider_by('.js-thread-divider', 2000)

    assert_in_delta 200, pane_width('#thread'), 2
  end

  test 'dragging the sidebar divider right widens the sidebar and remembers it' do
    assert_selector '.js-sidebar-divider'
    before = pane_width('.flex-sidebar')

    drag_divider_by('.js-sidebar-divider', 100)

    assert_in_delta before + 100, pane_width('.flex-sidebar'), 2
    assert_equal pane_width('.flex-sidebar').round.to_s, stored_width('octobox:sidebar-width')

    visit current_path
    assert_selector '.js-sidebar-divider'
    assert_in_delta before + 100, pane_width('.flex-sidebar'), 2
  end

  test 'the sidebar cannot be dragged narrower than the minimum' do
    assert_selector '.js-sidebar-divider'

    drag_divider_by('.js-sidebar-divider', -2000)

    assert_in_delta 200, pane_width('.flex-sidebar'), 2
  end

  private

  def pane_width(selector)
    page.evaluate_script("document.querySelector('#{selector}').getBoundingClientRect().width")
  end

  def stored_width(key)
    page.evaluate_script("localStorage.getItem('#{key}')")
  end

  def drag_divider_by(selector, dx)
    box = page.evaluate_script("document.querySelector('#{selector}').getBoundingClientRect().toJSON()")
    x = box['x'] + box['width'] / 2
    y = box['y'] + box['height'] / 2
    page.driver.with_playwright_page do |pw|
      pw.mouse.move(x, y)
      pw.mouse.down
      pw.mouse.move(x + dx, y, steps: 5)
      pw.mouse.up
    end
  end
end
