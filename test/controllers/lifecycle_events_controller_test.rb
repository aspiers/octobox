# frozen_string_literal: true

require 'test_helper'

class LifecycleEventsControllerTest < ActionDispatch::IntegrationTest
  setup do
    stub_background_jobs_enabled(value: false)
    stub_include_comments
    stub_notifications_request
    stub_repository_request
    @user = create(:user)
    sign_in_as(@user)
    @repository = Repository.find_by!(full_name: 'octobox/octobox')
    @repository.update!(private: false)
    @subject = create(:subject, repository: @repository, comment_count: nil)
    @notification = create(
      :notification,
      user: @user,
      subject_url: @subject.url,
      repository_full_name: @repository.full_name,
      subject_type: 'PullRequest'
    )
  end

  test 'fetches and renders lifecycle events with native GitHub links' do
    stub_timeline(file_fixture('lifecycle_timeline.json').read)
    LifecycleEvents::Refresh.new(subject: @subject).call

    get expand_comments_notification_path(@notification)

    assert_response :success
    assert_select '.lifecycle-events h3', count: 0
    assert_select '.lifecycle-event[data-preview-entry]', count: 11
    assert_select '[data-event-type="closed"]', text: /closed this pull request.*via commit 1111111/m
    assert_select '[data-event-type="committed"]', text: /Mona Lisa.*committed 2222222.*Keep lifecycle history/m
    assert_select '[data-event-type="labeled"]', count: 0
    assert_select 'a[href="https://github.com/octobox/octobox/commit/1111111111111111111111111111111111111111"]'
    assert_select "a[href=\"#{@subject.html_url}#event-8101\"]"
    assert_requested(:get, "#{@subject.url}/timeline?page=1&per_page=100") do |request|
      request.headers['Authorization'].blank?
    end
  end

  test 'paginates lifecycle events with the conversation and expands beyond 50 events' do
    @subject.update!(comment_count: 51)
    51.times do |index|
      create(:comment, subject: @subject, created_at: Time.utc(2026, 7, 1) + index.minutes)
    end
    snapshot = create(
      :lifecycle_event_snapshot,
      subject: @subject,
      total_count: 55,
      refreshed_at: 1.minute.ago
    )
    55.times do |index|
      create(
        :lifecycle_event,
        lifecycle_event_snapshot: snapshot,
        github_identity: "github:#{index}",
        actor_login: "actor#{index}",
        occurred_at: Time.utc(2026, 8, 1) + index.minutes
      )
    end

    get notification_path(@notification)

    assert_response :success
    assert_select '#more-comments a', text: /View 101 more conversation entries/
    assert_select '.lifecycle-event', count: 5
    actors = css_select('.lifecycle-event').map { |node| node.text[/actor\d+/] }
    assert_equal 'actor50', actors.first
    assert_equal 'actor54', actors.last

    get expand_comments_notification_path(@notification)

    assert_select '#more-comments', count: 0
    assert_select '.lifecycle-event', count: 55
    actors = css_select('.lifecycle-event').map { |node| node.text[/actor\d+/] }
    assert_equal 'actor0', actors.first
    assert_equal 'actor54', actors.last
  end

  test 'expanding review conversations retains lifecycle events' do
    snapshot = create(:lifecycle_event_snapshot, subject: @subject, total_count: 1, refreshed_at: 1.minute.ago)
    create(:lifecycle_event, lifecycle_event_snapshot: snapshot, actor_login: 'lifecycle-actor')

    get expand_comments_notification_path(@notification)

    assert_response :success
    assert_select '.lifecycle-event', text: /lifecycle-actor/
  end

  test 'does not render or retain a public snapshot after a repository becomes private' do
    @repository.update!(private: true)
    public_snapshot = create(:lifecycle_event_snapshot, subject: @subject)
    event = create(:lifecycle_event, lifecycle_event_snapshot: public_snapshot, actor_login: 'secret-actor')
    stub_timeline('[]')

    get notification_path(@notification)

    assert_response :success
    refute_includes response.body, event.actor_login
    refute LifecycleEventSnapshot.exists?(public_snapshot.id)
    assert LifecycleEventSnapshot.exists?(subject: @subject, viewer: @user)
  end

  test 'does not turn an unsafe actor name into a link' do
    snapshot = create(:lifecycle_event_snapshot, subject: @subject, refreshed_at: 1.minute.ago)
    create(:lifecycle_event, lifecycle_event_snapshot: snapshot, actor_login: 'Mona Lisa')

    get notification_path(@notification)

    assert_response :success
    assert_includes response.body, 'Mona Lisa'
    assert_select '.lifecycle-event a[href*="Mona%20Lisa"]', count: 0
  end

  test 'interleaves lifecycle events with comments and reviews chronologically' do
    @subject.update!(comment_count: 3)
    earlier = create(:comment, subject: @subject, created_at: Time.utc(2026, 1, 1, 10, 10))
    review = create(:comment, subject: @subject, activity_kind: 'pull_request_review',
                    review_state: 'APPROVED', created_at: Time.utc(2026, 1, 1, 10, 15))
    later = create(:comment, subject: @subject, created_at: Time.utc(2026, 1, 1, 10, 30))
    snapshot = create(:lifecycle_event_snapshot, subject: @subject, refreshed_at: 1.minute.ago)
    create(:lifecycle_event, lifecycle_event_snapshot: snapshot, event_type: 'merged',
           github_identity: 'github:merge-interleave', actor_login: 'andrew',
           occurred_at: Time.utc(2026, 1, 1, 10, 20))

    get notification_path(@notification)

    assert_response :success
    entries = css_select('.discussion-thread .card-comment[id], .discussion-thread .lifecycle-event')
    identities = entries.map { |node| node['id'] || node['data-event-identity'] }
    assert_equal ["comment-#{earlier.id}", "review-#{review.id}", 'github:merge-interleave',
                  "comment-#{later.id}"], identities
    assert_select '.lifecycle-events h3', count: 0
  end

  test 'paginates mixed entries together and retains their order when expanded' do
    @subject.update!(comment_count: 52)
    start = Time.utc(2026, 1, 1)
    snapshot = create(:lifecycle_event_snapshot, subject: @subject, refreshed_at: 1.minute.ago)
    older = 48.times.map do |index|
      comment = create(:comment, subject: @subject, created_at: start - (48 - index).minutes)
      "comment-#{comment.id}"
    end
    expected = older + 8.times.map do |index|
      if index.even?
        comment = create(:comment, subject: @subject, created_at: start + index.minutes)
        "comment-#{comment.id}"
      else
        event = create(:lifecycle_event, lifecycle_event_snapshot: snapshot,
                       github_identity: "github:mixed-#{index}", occurred_at: start + index.minutes)
        event.github_identity
      end
    end

    get notification_path(@notification)

    assert_equal expected.last(5), conversation_identities
    assert_select '#more-comments a', text: /View 51 more conversation entries/

    get expand_comments_notification_path(@notification)

    assert_equal expected, conversation_identities
    assert_select '#more-comments', count: 0
  end

  test 'uses only the current private viewer snapshot in the mixed conversation' do
    @repository.update!(private: true)
    snapshot = create(:lifecycle_event_snapshot, subject: @subject, viewer: @user,
                      scope_key: "viewer:#{@user.id}", refreshed_at: 1.minute.ago)
    create(:lifecycle_event, lifecycle_event_snapshot: snapshot, actor_login: 'visible-actor')
    other_user = create(:user)
    other_snapshot = create(:lifecycle_event_snapshot, subject: @subject, viewer: other_user,
                            scope_key: "viewer:#{other_user.id}", refreshed_at: 1.minute.ago)
    create(:lifecycle_event, lifecycle_event_snapshot: other_snapshot, actor_login: 'other-viewer-secret')

    get notification_path(@notification)

    assert_select '.lifecycle-event', count: 1, text: /visible-actor/
    refute_includes response.body, 'other-viewer-secret'
  end

  test 'does not expose a private snapshot after the viewer loses credentials' do
    @repository.update!(private: true)
    snapshot = create(:lifecycle_event_snapshot, subject: @subject, viewer: @user,
                      scope_key: "viewer:#{@user.id}", refreshed_at: 1.minute.ago)
    create(:lifecycle_event, lifecycle_event_snapshot: snapshot, actor_login: 'revoked-secret')
    User.any_instance.stubs(:effective_access_token).returns(nil)

    get notification_path(@notification)

    refute_includes response.body, 'revoked-secret'
    assert_select '.lifecycle-event', count: 0
  end

  test 'does not expose unsupported comments when lifecycle events are available' do
    snapshot = create(:lifecycle_event_snapshot, subject: @subject, refreshed_at: 1.minute.ago)
    create(:lifecycle_event, lifecycle_event_snapshot: snapshot)
    create(:comment, subject: @subject, body: 'unsupported-comment')

    get notification_path(@notification)

    assert_select '.lifecycle-event', count: 1
    refute_includes response.body, 'unsupported-comment'
  end

  private

  def conversation_identities
    css_select('.discussion-thread .card-comment[id], .discussion-thread .lifecycle-event').map do |node|
      node['id'] || node['data-event-identity']
    end
  end

  def stub_timeline(body)
    stub_request(:get, "#{@subject.url}/timeline")
      .with(query: { page: 1, per_page: 100 })
      .to_return(status: 200, body: body, headers: { 'Content-Type' => 'application/json' })
  end
end
