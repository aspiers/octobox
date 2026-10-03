# frozen_string_literal: true
require 'test_helper'

class CiWorkflowPreviewTest < ActiveSupport::TestCase
  test 'parses the reported workflow status attempt and branch without expanding it' do
    preview = CiWorkflowPreview.new('CI workflow run, Attempt #2 failed for issue-691-pi-permission-system-persist-approved-pe branch')

    assert_equal 'CI', preview.workflow
    assert_equal 'Failed', preview.status
    assert_equal '2', preview.attempt
    assert_equal 'issue-691-pi-permission-system-persist-approved-pe', preview.branch
  end

  test 'recognizes reported statuses and optional attempt numbers' do
    {
      'succeeded' => 'Succeeded', 'failed' => 'Failed', 'cancelled' => 'Cancelled',
      'canceled' => 'Cancelled', 'pending' => 'Pending', 'queued' => 'Queued',
      'in progress' => 'In progress', 'completed' => 'Completed'
    }.each do |reported, status|
      preview = CiWorkflowPreview.new("Build and test workflow run #{reported} for feature/my-branch branch")
      assert_equal 'Build and test', preview.workflow
      assert_equal status, preview.status
      assert_equal 'feature/my-branch', preview.branch
      assert_nil preview.attempt
    end
    assert_equal '123', CiWorkflowPreview.new('CI workflow run, Attempt #123 failed for main branch').attempt
  end

  test 'unrecognized titles remain raw rather than inventing run information' do
    ['Something unexpected', 'CI workflow run timed out for main branch', nil].each do |title|
      preview = CiWorkflowPreview.new(title)
      title.nil? ? assert_nil(preview.title) : assert_equal(title, preview.title)
      assert_nil preview.workflow
      assert_nil preview.status
      assert_nil preview.branch
      assert_nil preview.attempt
    end
  end

  test 'CheckSuite preview eligibility uses settings and visibility without becoming subjectable' do
    stub_include_comments
    user = create(:user, display_comments: true)
    notification = build(:notification, user: user, subject_type: 'CheckSuite', subject_url: 'https://github.com/octobox/octobox/actions')
    assert_nil notification.subject
    refute notification.subjectable?
    assert notification.display_thread?

    notification.stubs(:display?).returns(false)
    refute notification.display_thread?
    notification.stubs(:display?).returns(true)
    user.display_comments = false
    refute notification.display_thread?
    user.display_comments = true
    stub_include_comments(value: false)
    refute notification.display_thread?
  end

  test 'unsupported types stay external and Issue and PullRequest eligibility is unchanged' do
    stub_include_comments
    user = create(:user, display_comments: true)
    refute build(:notification, user: user, subject_type: 'Discussion').display_thread?
    %w[Issue PullRequest].each do |type|
      notification = create(:notification, user: user, subject_type: type)
      refute notification.display_thread?
      create(:subject, notifications: [notification])
      assert notification.reload.display_thread?
    end
  end
end
