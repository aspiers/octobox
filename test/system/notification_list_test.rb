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

  test 'autoloads as many as 50 comments in the notification preview' do
    Octobox.stubs(:include_comments?).returns(true)
    subject = create(:subject, notifications: [@notification], comment_count: 50)
    create_list(:comment, 50, subject: subject)
    visit '/'

    within "#notification-#{@notification.id}" do
      click_link 'Fix the widget'
    end

    assert_selector '.discussion-thread .card-comment', count: 50
    assert_no_selector '#more-comments'
  end

  test 'keeps the expansion flow above 50 comments' do
    Octobox.stubs(:include_comments?).returns(true)
    subject = create(:subject, notifications: [@notification], comment_count: 51)
    create_list(:comment, 51, subject: subject)
    visit '/'

    within "#notification-#{@notification.id}" do
      click_link 'Fix the widget'
    end

    assert_selector '.discussion-thread .card-comment', count: 5
    click_link 'View 46 more comments and reviews'
    assert_selector '.discussion-thread .card-comment', count: 51
    assert_no_selector '#more-comments'
  end

  test 'announces arrivals without inserting rows and clears the notice on refresh' do
    Octobox.config.stubs(:push_notifications).returns(true)
    visit '/?unread=true'

    initial_row_ids = all("tr[id^='notification-']").map { |row| row[:id] }
    assert_selector "meta[name='push_notifications']", visible: :all

    page.execute_script(<<~JS)
      App.notifications.received({ arrived: true });
      App.notifications.received({ arrived: true });
    JS

    assert_selector '.js-new-notifications:not(.d-none)', text: '2 new notifications. Click to refresh.'
    assert_equal initial_row_ids, all("tr[id^='notification-']").map { |row| row[:id] }

    find('.js-new-notifications-refresh').click
    assert_selector '.js-new-notifications.d-none', visible: :all
    assert_current_path '/?unread=true'
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

  test 'view more comments uses full-page navigation' do
    @user.notifications.delete_all
    notification = create(:notification, user: @user, subject_title: 'Busy discussion')
    subject = create(:subject, notifications: [notification], comment_count: 51)
    51.times { create(:comment, subject: subject) }

    visit notification_path(notification)
    assert_selector '.card-comment', count: 5

    within '#more-comments' do
      find("a[href$='#{expand_comments_notification_path(notification)}']").click
    end

    assert_current_path expand_comments_notification_path(notification)
    assert_selector '.card-comment', count: 51
    assert_no_selector '#more-comments'
  end
end
