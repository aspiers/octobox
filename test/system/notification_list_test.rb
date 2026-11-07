# frozen_string_literal: true

require 'application_system_test_case'

class NotificationListTest < ApplicationSystemTestCase
  setup do
    @user = create(:user, disable_confirmations: true)
    @notification = create(:notification, user: @user, subject_title: 'Fix the widget')
    @unread_notification = create(:notification, user: @user, unread: true, subject_title: 'Update docs')
    @read_notification = create(:notification, user: @user, unread: false, subject_title: 'Old issue')
    sign_in_as(@user)
  end

  test 'notification table renders with notifications' do
    assert_selector 'table.js-table-notifications'
    assert_text 'Fix the widget'
    assert_text 'Update docs'
    assert_text 'Old issue'
  end

  test 'unread notifications have active class' do
    row = find("#notification-#{@unread_notification.id}")
    assert_includes row[:class], 'active'
  end

  test 'read notifications do not have active class' do
    row = find("#notification-#{@read_notification.id}")
    refute_includes row[:class].split(' '), 'active'
  end

  test 'sidebar inbox link is active by default' do
    within '.flex-sidebar' do
      assert_selector 'a.nav-link.active', text: 'Inbox'
    end
  end

  test 'sidebar archive link navigates to archive view' do
    within '.flex-sidebar' do
      click_link 'Archive'
    end
    assert_current_path(/archive=true/)
    within '.flex-sidebar' do
      assert_selector 'a.nav-link.active', text: 'Archive'
    end
  end

  test 'notification navigation preserves the draft sidebar filter' do
    Octobox.stubs(:include_comments?).returns(true)
    subject = create(:subject, notifications: [@notification], draft: true, comment_count: 60)
    create_list(:comment, 60, subject: subject)
    create(:subject, notifications: [@unread_notification], draft: true)
    visit '/?draft=true'

    within "#notification-#{@notification.id}" do
      click_link 'Fix the widget'
    end

    assert_current_path notification_path(@notification, draft: true)
    within '.flex-sidebar' do
      assert_selector 'a.nav-link.active', text: 'Draft'
    end
    within '.filter-options' do
      assert_link 'Draft'
    end
    neighbor = first('a.previous.btn-outline-dark, a.next.btn-outline-dark')
    assert_equal notification_path(@unread_notification, draft: true), URI.parse(neighbor[:href]).request_uri

    all("a[href*='/expand_comments']", minimum: 2).each do |link|
      assert_includes link[:href], 'draft=true'
    end

    find('#more-comments a').click
    assert_current_path expand_comments_notification_path(@notification, draft: true)
    assert_no_selector '#more-comments'

    first('a.previous.btn-outline-dark, a.next.btn-outline-dark').click
    assert_current_path notification_path(@unread_notification, draft: true)
  end

  test 'sidebar starred link navigates to starred view' do
    create(:notification, user: @user, starred: true, subject_title: 'Starred item')
    within '.flex-sidebar' do
      click_link 'Starred'
    end
    assert_current_path(/starred=true/)
    within '.flex-sidebar' do
      assert_selector 'a.nav-link.active', text: 'Starred'
    end
    assert_text 'Starred item'
  end

  test 'clicking a sidebar filter keeps the clicked item where it was on screen' do
    30.times do |i|
      create(:notification, user: @user, repository_full_name: format('acme/repo-%02d', i), repository_owner_name: 'acme')
    end
    page.current_window.resize_to(1400, 500)
    visit '/'
    link = "document.querySelector(\"li[title='acme/repo-15'] a\")"
    page.execute_script(<<~JS)
      window.sidebarProbe = true;
      var sidebar = document.querySelector('.flex-sidebar');
      sidebar.scrollTop += #{link}.getBoundingClientRect().top - sidebar.getBoundingClientRect().top - 200;
    JS
    top_before = page.evaluate_script("#{link}.getBoundingClientRect().top")
    sidebar_top = page.evaluate_script("document.querySelector('.flex-sidebar').getBoundingClientRect().top")
    assert_in_delta 200, top_before - sidebar_top, 1, 'sidebar must scroll far enough to place the link'

    find("li[title='acme/repo-15'] a").click

    assert_selector "li.active[title='acme/repo-15']"
    assert page.evaluate_script('window.sidebarProbe'), 'expected a Turbolinks visit, not a full page load'
    assert_in_delta top_before, page.evaluate_script("#{link}.getBoundingClientRect().top"), 1
  ensure
    page.current_window.resize_to(1400, 900)
  end
end
