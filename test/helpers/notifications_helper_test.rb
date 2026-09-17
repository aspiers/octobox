require 'test_helper'

class NotificationsHelperTest < ActionView::TestCase
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
