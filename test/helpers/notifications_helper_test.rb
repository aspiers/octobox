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
end
