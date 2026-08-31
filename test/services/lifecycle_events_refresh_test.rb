# frozen_string_literal: true

require 'test_helper'

class LifecycleEventsRefreshTest < ActiveSupport::TestCase
  class FakeClient
    attr_reader :pages

    def initialize(&response)
      @response = response
      @pages = []
    end

    def get(_url, options)
      pages << options[:page]
      @response.call(options[:page])
    end
  end

  setup do
    @repository = create(:repository, private: false)
    @subject = create(:subject, repository: @repository)
    @timeline = Oj.load(file_fixture('lifecycle_timeline.json').read)
  end

  test 'stores allowlisted lifecycle events and their context' do
    client = FakeClient.new { @timeline }

    result = refresh(client: client)

    assert_equal :complete, result.outcome
    assert_equal 'complete', result.snapshot.status
    assert_equal 11, result.snapshot.total_count
    assert_equal [1], client.pages
    assert_equal LifecycleEvent::EVENT_TYPES.sort,
                 result.snapshot.lifecycle_events.pluck(:event_type).sort

    closed = result.snapshot.lifecycle_events.find_by!(event_type: 'closed')
    assert_equal 'octocat', closed.actor_login
    assert_equal '1111111111111111111111111111111111111111', closed.commit_sha
    assert_equal 'github:LE_closed_8101', closed.github_identity

    force_push = result.snapshot.lifecycle_events.find_by!(event_type: 'head_ref_force_pushed')
    assert_equal '3333333333333333333333333333333333333333', force_push.before_commit_sha
    assert_equal '4444444444444444444444444444444444444444', force_push.after_commit_sha

    ref_change = result.snapshot.lifecycle_events.find_by!(event_type: 'base_ref_changed')
    assert_equal 'main', ref_change.previous_ref_name
    assert_equal 'stable', ref_change.current_ref_name
  end

  test 'fetches every page until a short final page' do
    first_page = Array.new(99) { |index| metadata_event(index) }
    first_page << @timeline.first
    client = FakeClient.new { |page| page == 1 ? first_page : [@timeline.second] }

    result = refresh(client: client)

    assert_equal :complete, result.outcome
    assert_equal [1, 2], client.pages
    assert_equal 2, result.snapshot.total_count
  end

  test 'keeps the last complete snapshot when pagination reaches the bound' do
    snapshot = create(:lifecycle_event_snapshot, subject: @subject)
    old_event = create(:lifecycle_event, lifecycle_event_snapshot: snapshot)
    full_page = Array.new(100) { |index| metadata_event(index) }
    client = FakeClient.new { full_page }

    result = refresh(client: client)

    assert_equal :incomplete, result.outcome
    assert_equal 'incomplete', result.snapshot.status
    assert_equal (1..LifecycleEvents::Refresh::MAX_PAGES).to_a, client.pages
    assert LifecycleEvent.exists?(old_event.id)
    assert_equal 1, result.snapshot.total_count
  end

  test 'keeps the last complete snapshot after a transient failure' do
    snapshot = create(:lifecycle_event_snapshot, subject: @subject)
    old_event = create(:lifecycle_event, lifecycle_event_snapshot: snapshot)
    client = FakeClient.new { raise Faraday::ConnectionFailed, 'offline' }

    result = refresh(client: client)

    assert_equal :stale, result.outcome
    assert_equal 'stale', result.snapshot.status
    assert LifecycleEvent.exists?(old_event.id)
  end

  test 'purges a shared snapshot when GitHub returns not found' do
    snapshot = create(:lifecycle_event_snapshot, subject: @subject)
    event = create(:lifecycle_event, lifecycle_event_snapshot: snapshot)
    client = FakeClient.new { raise Octokit::NotFound.new }

    result = refresh(client: client)

    assert_equal :withheld, result.outcome
    refute LifecycleEventSnapshot.exists?(snapshot.id)
    refute LifecycleEvent.exists?(event.id)
  end

  test 'discards a completion superseded by a concurrent refresh' do
    snapshot = create(:lifecycle_event_snapshot, subject: @subject, generation: 3)
    old_event = create(:lifecycle_event, lifecycle_event_snapshot: snapshot)
    client = FakeClient.new do
      snapshot.reload.increment!(:generation)
      @timeline
    end

    result = refresh(client: client)

    assert_equal :superseded, result.outcome
    assert LifecycleEvent.exists?(old_event.id)
    refute result.snapshot.lifecycle_events.exists?(event_type: 'merged')
  end

  test 'uses a viewer-scoped snapshot for an authorized private repository' do
    @repository.update!(private: true)
    viewer = create(:user)
    create(
      :notification,
      user: viewer,
      subject_url: @subject.url,
      repository_full_name: @repository.full_name
    )

    result = refresh(client: FakeClient.new { @timeline }, viewer: viewer)

    assert_equal :complete, result.outcome
    assert_equal viewer, result.snapshot.viewer
    assert_equal "viewer:#{viewer.id}", result.snapshot.scope_key
    refute LifecycleEventSnapshot.exists?(subject: @subject, scope_key: 'public')
  end

  test 'purges and withholds private data without viewer authorization' do
    @repository.update!(private: true)
    public_snapshot = create(:lifecycle_event_snapshot, subject: @subject)
    create(:lifecycle_event, lifecycle_event_snapshot: public_snapshot)
    viewer = create(:user, access_token: nil)
    create(
      :notification,
      user: viewer,
      subject_url: @subject.url,
      repository_full_name: @repository.full_name
    )

    result = refresh(client: FakeClient.new { flunk 'timeline should not be requested' }, viewer: viewer)

    assert_equal :withheld, result.outcome
    refute LifecycleEventSnapshot.exists?(public_snapshot.id)
  end

  test 'reuses a fresh snapshot without requesting GitHub' do
    snapshot = create(:lifecycle_event_snapshot, subject: @subject, refreshed_at: 1.minute.ago)
    client = FakeClient.new { flunk 'timeline should not be requested' }

    result = refresh(client: client, force: false)

    assert_equal :fresh, result.outcome
    assert_equal snapshot, result.snapshot
    assert_empty client.pages
  end

  private

  def refresh(client:, viewer: nil, force: true)
    LifecycleEvents::Refresh.new(subject: @subject, viewer: viewer, client: client).call(force: force)
  end

  def metadata_event(index)
    {
      'id' => index + 10_000,
      'event' => 'labeled',
      'created_at' => '2026-08-01T20:00:00Z'
    }
  end
end
