# frozen_string_literal: true
require 'application_system_test_case'

class CiWorkflowPreviewSystemTest < ApplicationSystemTestCase
  setup do
    stub_include_comments
    stub_background_jobs_enabled(value: false)
    stub_fetch_subject_enabled(value: false)
    @user = create(:user, display_comments: true)
    @notification = create(:notification, user: @user, subject_type: 'CheckSuite', reason: 'ci_activity', unread: false,
      subject_title: 'CI workflow run, Attempt #2 failed for issue-691-pi-permission-system-persist-approved-pe branch',
      repository_full_name: 'gotgenes/pi-packages', subject_url: 'https://github.com/gotgenes/pi-packages/actions')
    sign_in_as(@user)
  end

  test 'clicking the notification opens its failure summary locally without fetching GitHub' do
    assert_nil @notification.subject
    WebMock.reset_executed_requests!
    within "#notification-#{@notification.id}" do
      find('a.thread-link[data-toggle=showthread]').click
    end
    within '.ci-workflow-preview' do
      assert_text 'Failed'
      assert_text 'Attempt'
      assert_text '2'
      assert_text 'issue-691-pi-permission-system-persist-approved-pe'
      assert_selector 'a[href="https://github.com/gotgenes/pi-packages/actions"]', text: 'Open Actions'
    end
    assert_no_selector '.discussion-thread, .expand_comments, #notification-thread form'
    assert_equal 1, page.windows.size
    assert_not_requested :get, /github\.com/
  end
end
