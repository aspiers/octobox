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

    get notification_path(@notification)

    assert_response :success
    assert_select '.lifecycle-events h3', text: /Lifecycle activity \(11\)/
    assert_select '.lifecycle-event', count: 11
    assert_select '[data-event-type="closed"]', text: /closed this pull request.*via commit 1111111/m
    assert_select '[data-event-type="committed"]', text: /Mona Lisa.*committed 2222222.*Keep lifecycle history/m
    assert_select '[data-event-type="labeled"]', count: 0
    assert_select 'a[href="https://github.com/octobox/octobox/commit/1111111111111111111111111111111111111111"]'
    assert_select "a[href=\"#{@subject.html_url}#event-8101\"]"
    assert_requested(:get, "#{@subject.url}/timeline?page=1&per_page=100") do |request|
      request.headers['Authorization'].blank?
    end
  end

  test 'renders only the latest 50 events in chronological order and shows the total' do
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
    assert_select '.lifecycle-events h3', text: /\(55\)/
    assert_select '.lifecycle-event', count: 50
    actors = css_select('.lifecycle-event').map { |node| node.text[/actor\d+/] }
    assert_equal 'actor5', actors.first
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

  private

  def stub_timeline(body)
    stub_request(:get, "#{@subject.url}/timeline")
      .with(query: { page: 1, per_page: 100 })
      .to_return(status: 200, body: body, headers: { 'Content-Type' => 'application/json' })
  end
end
