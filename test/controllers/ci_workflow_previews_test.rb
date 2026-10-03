# frozen_string_literal: true
require 'test_helper'

class CiWorkflowPreviewsTest < ActionDispatch::IntegrationTest
  setup do
    Octobox.config.stubs(:github_app).returns(false)
    stub_background_jobs_enabled(value: false)
    stub_fetch_subject_enabled(value: false)
    stub_include_comments
    stub_notifications_request
    stub_repository_request
    stub_comments_requests
    @user = create(:user, display_comments: true)
    sign_in_as(@user)
    @notification = create(:notification, user: @user, subject_type: 'CheckSuite', reason: 'ci_activity',
      repository_full_name: 'gotgenes/pi-packages',
      subject_title: 'CI workflow run, Attempt #2 failed for issue-691-pi-permission-system-persist-approved-pe branch',
      subject_url: 'https://github.com/gotgenes/pi-packages/actions', latest_comment_url: nil)
    WebMock.reset_executed_requests!
  end

  test 'list link opens a standalone nil-subject summary without GitHub requests' do
    assert_nil @notification.subject
    get '/'
    assert_select "#notification-#{@notification.id} a.thread-link[data-toggle=showthread][href='#{notification_path(@notification)}']"

    get notification_path(@notification), xhr: true
    assert_response :success
    assert_select '.ci-workflow-preview', count: 1 do
      assert_select 'dd', text: 'CI'
      assert_select 'dd', text: 'Failed'
      assert_select 'dd', text: '2'
      assert_select 'dd', text: 'issue-691-pi-permission-system-persist-approved-pe'
      assert_select 'dd', text: 'gotgenes/pi-packages'
      assert_select "time[datetime='#{@notification.updated_at.iso8601}']"
      assert_select 'a[href="https://github.com/gotgenes/pi-packages/actions"]', text: 'Open Actions'
    end
    assert_select '.discussion-thread, .expand_comments, form', count: 0
    assert_not_requested :get, /github\.com/
  end

  test 'same Actions URL does not share workflow data or need a Subject' do
    other = create(:notification, user: @user, subject_type: 'CheckSuite', subject_url: @notification.subject_url,
      subject_title: 'Deploy workflow run succeeded for release branch')
    get notification_path(other), xhr: true
    assert_select '.ci-workflow-preview dd', text: 'Deploy'
    assert_select '.ci-workflow-preview dd', text: 'Succeeded'
    assert_select '.ci-workflow-preview dd', text: 'release'
    assert_select '.ci-workflow-preview dd', text: 'Failed', count: 0
    assert_nil other.subject
    assert_nil @notification.subject
  end

  test 'unknown titles and markup are escaped and unsafe subject URLs are never linked' do
    @notification.update_columns(subject_title: '<script>alert(1)</script> Unknown workflow title',
      subject_url: 'javascript:alert(1)//https://github.com/gotgenes/pi-packages/actions')
    get notification_path(@notification), xhr: true
    assert_select '.ci-workflow-preview p', text: '<script>alert(1)</script> Unknown workflow title'
    assert_select 'script, a[href^="javascript:"]', count: 0
    assert_select '.ci-workflow-preview dd', text: 'Failed', count: 0
    assert_select '.ci-workflow-preview a[href="https://github.com/gotgenes/pi-packages/actions"]'

    @notification.update_columns(subject_title: '<img src=x onerror=alert(1)> workflow run failed for <svg onload=alert(1)> branch')
    get notification_path(@notification), xhr: true
    assert_select '.ci-workflow-preview dd', text: '<img src=x onerror=alert(1)>'
    assert_select '.ci-workflow-preview dd', text: '<svg onload=alert(1)>'
    assert_select '.ci-workflow-preview img, .ci-workflow-preview svg', count: 0
  end

  test 'Actions URL supports the configured GitHub domain and rejects malformed domains and repositories' do
    Octobox.config.stubs(:github_domain).returns('https://github.example.test')
    get notification_path(@notification), xhr: true
    assert_select '.ci-workflow-preview a[href="https://github.example.test/gotgenes/pi-packages/actions"]'

    ['javascript://github.example.test', 'https://evil.test@github.example.test', 'https://github.example.test?redirect=evil'].each do |domain|
      Octobox.config.stubs(:github_domain).returns(domain)
      get notification_path(@notification), xhr: true
      assert_select '.ci-workflow-preview a', count: 0
    end
    Octobox.config.stubs(:github_domain).returns('https://github.example.test')
    @notification.update_columns(repository_full_name: '../evil')
    get notification_path(@notification), xhr: true
    assert_select '.ci-workflow-preview a', count: 0
  end

  test 'preview settings disable list routing and direct summaries' do
    @user.update_column(:display_comments, false)
    get '/'
    assert_select "#notification-#{@notification.id} a.thread-link", count: 0
    get notification_path(@notification), xhr: true
    assert_select '.ci-workflow-preview', count: 0

    @user.update_column(:display_comments, true)
    stub_include_comments(value: false)
    get '/'
    assert_select "#notification-#{@notification.id} a.thread-link", count: 0
    get notification_path(@notification), xhr: true
    assert_select '.ci-workflow-preview', count: 0
  end

  test 'restricted private notifications do not expose summaries and other users cannot access them' do
    create(:repository, full_name: @notification.repository_full_name, private: true)
    Octobox.stubs(:io?).returns(true)
    Repository.any_instance.stubs(:display_subject?).returns(false)
    User.any_instance.stubs(:has_personal_plan?).returns(false)
    refute @notification.reload.display?
    get notification_path(@notification), xhr: true
    assert_select '.ci-workflow-preview', count: 0
    get '/'
    assert_select "#notification-#{@notification.id} a.thread-link", count: 0

    foreign = create(:notification, subject_type: 'CheckSuite', subject_title: 'Secret workflow run failed for private branch')
    assert_raises ActiveRecord::RecordNotFound do
      get notification_path(foreign), xhr: true
    end
  end

  test 'CheckSuite expansion and reply are rejected even if a shared Subject exists' do
    subject = create(:subject, notifications: [@notification], body: 'Unrelated shared body')
    create(:comment, subject: subject, body: 'Unrelated shared comment')
    get notification_path(@notification), xhr: true
    assert_select '.discussion-thread, form, .expand_comments', count: 0
    assert_select "#notification-thread[data-subject-id='']"
    assert_not_includes response.body, 'Unrelated shared body'
    assert_not_includes response.body, 'Unrelated shared comment'

    get expand_comments_notification_path(@notification), xhr: true
    assert_response :unprocessable_entity
    post comment_notification_path(@notification), params: { comment: { body: 'Not supported' } }, xhr: true
    assert_response :unprocessable_entity
    assert_equal 1, subject.comments.count
    assert_not_requested :post, /github\.com/
  end

  [true, false].each do |xhr|
    test "shared CheckSuite summary exits before discussion loading for xhr=#{xhr}" do
      create(:subject, notifications: [@notification], body: 'Unrelated shared body')
      Notification.any_instance.expects(:subject).never

      get notification_path(@notification), params: { repo: @notification.repository_full_name }, xhr: xhr

      assert_response :success
      assert_select '.ci-workflow-preview', count: 1
      assert_select '.ci-workflow-preview dd', text: 'Failed'
      assert_nil assigns(:comments), 'Standalone previews must return before preparing Subject discussion data'
      assert_not_includes response.body, 'Unrelated shared body'
      assert_not_requested :get, /github\.com/
    end
  end

  test 'nil-subject CheckSuite reply is rejected without error' do
    post comment_notification_path(@notification), params: { comment: { body: 'Not supported' } }, xhr: true
    assert_response :unprocessable_entity
  end
end
