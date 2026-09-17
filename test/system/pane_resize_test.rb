# frozen_string_literal: true

require 'application_system_test_case'

class PaneResizeTest < ApplicationSystemTestCase
  setup do
    stub_include_comments
    @user = create(:user, disable_confirmations: true)
    @notification = create(:notification, user: @user, subject: create(:subject), subject_title: 'Fix the widget')
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
    assert_in_delta percent_of_layout(pane_width('#thread')), stored_width('octobox:pane-width:thread').to_f, 0.1

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
    assert_in_delta percent_of_layout(pane_width('.flex-sidebar')), stored_width('octobox:pane-width:sidebar').to_f, 0.1

    visit current_path
    assert_selector '.js-sidebar-divider'
    assert_in_delta before + 100, pane_width('.flex-sidebar'), 2
  end

  test 'the sidebar cannot be dragged narrower than the minimum' do
    assert_selector '.js-sidebar-divider'

    drag_divider_by('.js-sidebar-divider', -2000)

    assert_in_delta 200, pane_width('.flex-sidebar'), 2
  end

  test 'the notification page has both dividers and applies remembered widths' do
    drag_divider_by('.js-sidebar-divider', 80)
    drag_divider_by('.js-thread-divider', -120)
    sidebar = pane_width('.flex-sidebar')
    thread = pane_width('#thread')

    visit "/notifications/#{@notification.id}"
    assert_selector '#notification-thread'
    assert_selector '.js-sidebar-divider'
    assert_selector '.js-thread-divider'
    assert_in_delta sidebar, pane_width('.flex-sidebar'), 2
    assert_in_delta thread, pane_width('#thread'), 2
  end

  test 'remembered widths are applied before the page scripts run' do
    drag_divider_by('.js-sidebar-divider', 80)
    sidebar = pane_width('.flex-sidebar')

    page.driver.with_playwright_page do |pw|
      pw.add_init_script(script: <<~JS)
        document.addEventListener('DOMContentLoaded', function() {
          window.sidebarWidthAtDomReady = document.querySelector('.flex-sidebar').getBoundingClientRect().width;
        });
      JS
    end
    visit current_path
    assert_selector '.js-sidebar-divider'

    assert_in_delta sidebar, page.evaluate_script('window.sidebarWidthAtDomReady'), 2
  end

  test 'panes keep their share of the width when the window size changes' do
    drag_divider_by('.js-sidebar-divider', 100)
    drag_divider_by('.js-thread-divider', -150)
    sidebar_share = pane_width('.flex-sidebar') / layout_width
    thread_share = pane_width('#thread') / layout_width

    page.current_window.resize_to(2400, 900)
    visit current_path
    assert_selector '.js-thread-divider'

    assert_in_delta sidebar_share, pane_width('.flex-sidebar') / layout_width, 0.005
    assert_in_delta thread_share, pane_width('#thread') / layout_width, 0.005
    assert_operator pane_width('.flex-sidebar'), :>, 300
  end

  private

  def layout_width
    pane_width('.flex-content')
  end

  def percent_of_layout(width)
    width / layout_width * 100
  end

  def pane_width(selector)
    # to_f: whole-pixel widths come back as Integers, which would divide as integers.
    page.evaluate_script("document.querySelector('#{selector}').getBoundingClientRect().width").to_f
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
