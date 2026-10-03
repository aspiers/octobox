require 'test_helper'

class NotificationsHelperTest < ActionView::TestCase
  test 'discussions get the discussion octicon and show their number' do
    notification = mock
    notification.stubs(:subject_type).returns('Discussion')
    notification.stubs(:subject_number).returns('779')
    notification.stubs(:subject_title).returns('Ultra HDR support')
    notification.stubs(:state).returns('open')
    notification.stubs(:draft?).returns(nil)
    notification.stubs(:user).returns(nil)

    assert_equal 'comment-discussion', notification_icon(notification)
    assert_equal 'Open discussion', notification_icon_title(notification)
    assert_includes subject_with_number(notification), '#779'
  end

  test 'returns true when equal' do
    query = "inbox:true state:open unread:true reason:team_mention"
    assert search_query_matches?(query, query), "search query should have matched"
  end

  test 'returns false when not equal' do
    query = "inbox:true state:open unread:true reason:team_mention"
    other_query = "inbox:true state:open unread:unread reason:team_mention"
    refute search_query_matches?(query, other_query), "search query should not have matched"
  end

  test 'returns true when equal despite formatting differences' do
    query = "inbox:true state:open unread:true reason:team_mention"
    other_query = "inbox: true state: open unread: true reason: team_mention"
    assert search_query_matches?(query, other_query), "search query should have matched"
  end

  test 'returns true when equal despite formatting differences and order' do
    query = "unread:true reason:team_mention inbox:true state:open"
    other_query = "inbox: true state: open unread: true reason: team_mention"
    assert search_query_matches?(query, other_query), "search query should have matched"
  end

  test 'uses GitHub status colors for issue and pull request badges' do
    expectations = [
      ['Issue', 'open', false, 'btn-open'],
      ['Issue', 'closed', false, 'btn-closed'],
      ['PullRequest', 'open', false, 'btn-open'],
      ['PullRequest', 'open', true, 'btn-draft'],
      ['PullRequest', 'closed', false, 'btn-closed-pr'],
      ['PullRequest', 'closed', true, 'btn-closed-pr'],
      ['PullRequest', 'merged', false, 'btn-merged'],
      ['PullRequest', 'merged', true, 'btn-merged']
    ]

    expectations.each do |subject_type, state, draft, expected_color|
      notification = mock
      notification.stubs(:display_subject?).returns(true)
      notification.stubs(:subject_type).returns(subject_type)
      notification.stubs(:state).returns(state)
      notification.stubs(:draft?).returns(draft)

      assert_equal expected_color, notification_button_color(notification),
                   "expected #{subject_type} #{state}#{' draft' if draft} to use #{expected_color}"
    end
  end

  test 'terminal pull request state outranks a stale draft flag' do
    user = mock
    user.stubs(:github_app_authorized?).returns(true)
    expectations = [
      ['closed', 'git-pull-request-closed', 'Closed pull request', 'text-danger', 'Closed'],
      ['merged', 'git-merge', 'Merged pull request', 'text-subscribed', 'Merged']
    ]

    expectations.each do |state, expected_icon, expected_icon_title, expected_icon_color, expected_button_title|
      notification = mock
      notification.stubs(:display_subject?).returns(true)
      notification.stubs(:subject_type).returns('PullRequest')
      notification.stubs(:state).returns(state)
      notification.stubs(:draft?).returns(true)
      notification.stubs(:user).returns(user)

      assert_equal expected_icon, notification_icon(notification)
      assert_equal expected_icon_title, notification_icon_title(notification)
      assert_equal expected_icon_color, notification_icon_color(notification)
      assert_equal expected_button_title, notification_button_title(notification)
    end
  end

  test 'compiles status badges with GitHub Primer emphasis colors' do
    expected_themes = {
      'light.css' => {
        'open' => '#1f883d', 'closed' => '#8250df', 'closed-pr' => '#cf222e',
        'merged' => '#8250df', 'draft' => '#59636e', 'failure-icon' => '#cf222e'
      },
      'dark.css' => {
        'open' => '#238636', 'closed' => '#8957e5', 'closed-pr' => '#da3633',
        'merged' => '#8957e5', 'draft' => '#656c76', 'failure-icon' => '#da3633'
      }
    }

    expected_themes.each do |asset_name, expected_colors|
      css = Rails.application.assets.find_asset(asset_name).to_s

      expected_colors.except('failure-icon').each do |name, color|
        assert_match(/\.btn-#{name}\s*\{[^}]*background-color:\s*#{color};/mi, css)
      end
      assert_match(/\.octicon\.failure,\s*\.octicon\.error\s*\{[^}]*fill:\s*#{expected_colors['failure-icon']}\s*!important;?/mi, css)
    end
  end

  test 'links lifecycle event users to their profile' do
    event = LifecycleEvent.new(actor_login: 'octocat')
    assert_dom_equal %(<a class="text-muted" target="_blank" rel="noopener" href="https://github.com/octocat">octocat</a>),
                     lifecycle_event_actor(event)
  end

  test 'links lifecycle event apps to their app page' do
    event = LifecycleEvent.new(actor_login: 'linear-code[bot]')
    assert_dom_equal %(<a class="text-muted" target="_blank" rel="noopener" href="https://github.com/apps/linear-code">linear-code[bot]</a>),
                     lifecycle_event_actor(event)
  end

  test 'does not link lifecycle event actors with unsafe names' do
    assert_equal 'evil]/x', lifecycle_event_actor(LifecycleEvent.new(actor_login: 'evil]/x'))
    assert_equal '[bot]', lifecycle_event_actor(LifecycleEvent.new(actor_login: '[bot]'))
    assert_equal 'Someone', lifecycle_event_actor(LifecycleEvent.new(actor_login: nil))
  end

  test 'treats a missing or refreshing lifecycle snapshot as pending' do
    assert lifecycle_events_pending?(nil)
    assert lifecycle_events_pending?(LifecycleEventSnapshot.new(status: 'refreshing'))
    refute lifecycle_events_pending?(LifecycleEventSnapshot.new(status: 'complete'))
    refute lifecycle_events_pending?(LifecycleEventSnapshot.new(status: 'stale'))
  end
end
