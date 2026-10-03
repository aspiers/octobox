# frozen_string_literal: true

require 'test_helper'

class MetadataEventsControllerTest < ActionDispatch::IntegrationTest
  class FakeClient
    def initialize(events)
      @events = events
    end

    def get(_url, _options)
      @events
    end
  end

  setup do
    Octobox.config.stubs(:github_app).returns(false)
    stub_background_jobs_enabled(value: false)
    stub_fetch_subject_enabled(value: false)
    stub_include_comments
    stub_notifications_request
    stub_repository_request
    @user = create(:user)
    sign_in_as(@user)
    @repository = Repository.find_by!(full_name: 'octobox/octobox')
    @repository.update!(private: false)
    @subject = create(:subject, repository: @repository, comment_count: nil)
    @notification = create(:notification, user: @user, subject_url: @subject.url,
                                           repository_full_name: @repository.full_name,
                                           subject_type: 'Issue')
  end

  test 'renders cached metadata chronologically with safe native and source links' do
    timeline = Oj.load(file_fixture('metadata_timeline.json').read)
    MetadataEvents::Refresh.new(subject: @subject, client: FakeClient.new(timeline)).call

    get notification_path(@notification)

    assert_response :success
    assert_select '.metadata-events h3', text: /Metadata activity \(12\)/
    assert_select '.metadata-event', count: 12
    assert_select '[data-event-type="renamed"]', text: /Escape <this> title.*Render metadata safely/m
    assert_select '[data-event-type="connected"] a[href="https://github.com/octobox/octobox/issues/42"]'
    assert_select "a[href=\"#{@subject.html_url}#event-9101\"]"
    assert_includes response.body, 'Related &lt;script&gt;alert(1)&lt;/script&gt;'
    refute_includes response.body, '<script>alert(1)</script>'
    assert_select '[data-event-type="closed"]', count: 0
  end

  test 'renders only the latest 50 cached events and reports the complete total' do
    snapshot = create(:metadata_event_snapshot, subject: @subject, total_count: 55)
    55.times do |index|
      create(:metadata_event, metadata_event_snapshot: snapshot,
                              github_identity: "github:#{index}",
                              actor_login: "actor#{index}",
                              occurred_at: Time.utc(2026, 8, 1) + index.minutes)
    end

    get notification_path(@notification)

    assert_select '.metadata-events h3', text: /\(55\)/
    assert_select '.metadata-event', count: 50
    actors = css_select('.metadata-event').map { |node| node.text[/actor\d+/] }
    assert_equal 'actor5', actors.first
    assert_equal 'actor54', actors.last
  end

  test 'retains cached metadata when expanding the conversation' do
    snapshot = create(:metadata_event_snapshot, subject: @subject, total_count: 1)
    create(:metadata_event, metadata_event_snapshot: snapshot)

    get expand_comments_notification_path(@notification)

    assert_response :success
    assert_select '.metadata-event', count: 1
  end

  test 'queues a refresh without making a GitHub request in the preview action' do
    stub_background_jobs_enabled(value: true)

    get notification_path(@notification)

    assert_not_requested(:get, %r{/timeline})
    assert_response :success
    assert_sidekiq_job_enqueued(RefreshMetadataEventsWorker, @subject.id, nil)
  end

  test 'marks preserved incomplete data as out of date' do
    snapshot = create(:metadata_event_snapshot, subject: @subject, status: 'incomplete')
    create(:metadata_event, metadata_event_snapshot: snapshot)

    get notification_path(@notification)

    assert_select '.metadata-events[data-status="incomplete"]'
    assert_select '.metadata-events-stale', text: /may be out of date/
  end

  test 'purges and does not render public data after privatization' do
    snapshot = create(:metadata_event_snapshot, subject: @subject)
    event = create(:metadata_event, metadata_event_snapshot: snapshot,
                                    actor_login: 'private-actor')
    @repository.update!(private: true)

    get notification_path(@notification)

    assert_response :success
    refute_includes response.body, event.actor_login
    refute MetadataEventSnapshot.exists?(snapshot.id)
  end

  test 'purges public data even when the private preview is not displayable' do
    snapshot = create(:metadata_event_snapshot, subject: @subject)
    create(:metadata_event, metadata_event_snapshot: snapshot)
    @repository.update!(private: true)
    Octobox.stubs(:io?).returns(true)

    get notification_path(@notification)

    assert_response :success
    refute MetadataEventSnapshot.exists?(snapshot.id)
    assert_select '.metadata-events', count: 0
  end

  test 'does not turn unsafe actor or native URL values into links' do
    snapshot = create(:metadata_event_snapshot, subject: @subject)
    create(:metadata_event, metadata_event_snapshot: snapshot,
                            actor_login: '<img src=x onerror=alert(1)>',
                            native_url: 'https://github.com.evil.test/octobox/octobox')

    get notification_path(@notification)

    assert_includes response.body, '&lt;img src=x onerror=alert(1)&gt;'
    refute_includes response.body, '<img src=x onerror=alert(1)>'
    assert_select '.metadata-event a[href*="evil.test"]', count: 0
  end
end
