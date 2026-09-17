# frozen_string_literal: true

require 'application_system_test_case'

class PreviewPaneResizeTest < ApplicationSystemTestCase
  setup do
    stub_include_comments
    @user = create(:user, disable_confirmations: true)
    create(:notification, user: @user, subject_title: 'Fix the widget')
    sign_in_as(@user)
    # Wide enough that the preview pane, and so its divider, are always shown.
    page.current_window.resize_to(1800, 900)
  end

  test 'divider is hidden while the preview pane is hidden' do
    page.current_window.resize_to(1400, 900)
    assert_no_selector '.js-thread-divider'
    assert_selector '.js-thread-divider', visible: :hidden
  end

  test 'dragging the divider left widens the preview pane and remembers it' do
    assert_selector '.js-thread-divider'
    before = pane_width

    drag_divider_by(-150)

    assert_in_delta before + 150, pane_width, 2
    assert_equal pane_width.round.to_s, page.evaluate_script("localStorage.getItem('octobox:thread-width')")

    visit current_path
    assert_selector '.js-thread-divider'
    assert_in_delta before + 150, pane_width, 2
  end

  test 'dragging the divider right narrows the preview pane' do
    assert_selector '.js-thread-divider'
    before = pane_width

    drag_divider_by(120)

    assert_in_delta before - 120, pane_width, 2
  end

  test 'the pane cannot be dragged narrower than the minimum' do
    assert_selector '.js-thread-divider'

    drag_divider_by(2000)

    assert_in_delta 200, pane_width, 2
  end

  private

  def pane_width
    page.evaluate_script("document.getElementById('thread').getBoundingClientRect().width")
  end

  def drag_divider_by(dx)
    box = page.evaluate_script("document.querySelector('.js-thread-divider').getBoundingClientRect().toJSON()")
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
