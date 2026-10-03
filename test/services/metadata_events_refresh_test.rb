# frozen_string_literal: true

require 'test_helper'

class MetadataEventsRefreshTest < ActiveSupport::TestCase
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
    @timeline = Oj.load(file_fixture('metadata_timeline.json').read)
  end

  test 'stores only metadata events with actor, before, after, source and native context' do
    result = refresh(client: FakeClient.new { @timeline })

    assert_equal :complete, result.outcome
    assert_equal MetadataEvent::EVENT_TYPES.sort,
                 result.snapshot.metadata_events.pluck(:event_type).sort
    assert_equal 12, result.snapshot.total_count

    renamed = result.snapshot.metadata_events.find_by!(event_type: 'renamed')
    assert_equal 'octocat', renamed.actor_login
    assert_equal({ 'title' => 'Escape <this> title' }, renamed.before_metadata)
    assert_equal({ 'title' => 'Render metadata safely' }, renamed.after_metadata)
    assert_equal 'github:MDE_renamed_9101', renamed.github_identity
    assert_equal "#{@subject.html_url}#event-9101", renamed.native_url

    connected = result.snapshot.metadata_events.find_by!(event_type: 'connected')
    assert_equal 'octobox/octobox', connected.source_context['repository_full_name']
    assert_equal 42, connected.source_context['number']
    assert_equal 'https://github.com/octobox/octobox/issues/42', connected.source_context['url']
  end

  test 'fetches every page through a short final page' do
    ignored = Array.new(100) { |index| ignored_event(index) }
    client = FakeClient.new { |page| page == 1 ? ignored : [@timeline.first] }

    result = refresh(client: client)

    assert_equal :complete, result.outcome
    assert_equal [1, 2], client.pages
    assert_equal 1, result.snapshot.total_count
  end

  test 'preserves prior events when complete refreshes are additive' do
    snapshot = create(:metadata_event_snapshot, subject: @subject)
    old_event = create(:metadata_event, metadata_event_snapshot: snapshot,
                                        github_identity: 'github:old')

    result = refresh(client: FakeClient.new { [@timeline.first] })

    assert_equal :complete, result.outcome
    assert MetadataEvent.exists?(old_event.id)
    assert_equal 2, result.snapshot.total_count
  end

  test 'preserves the last snapshot when pagination reaches its bound' do
    snapshot = create(:metadata_event_snapshot, subject: @subject)
    old_event = create(:metadata_event, metadata_event_snapshot: snapshot)
    full_page = Array.new(100) { |index| ignored_event(index) }
    client = FakeClient.new { full_page }

    result = refresh(client: client)

    assert_equal :incomplete, result.outcome
    assert_equal (1..MetadataEvents::Refresh::MAX_PAGES).to_a, client.pages
    assert MetadataEvent.exists?(old_event.id)
    assert_equal 'incomplete', result.snapshot.status
  end

  test 'preserves the last snapshot after a transient failure' do
    snapshot = create(:metadata_event_snapshot, subject: @subject)
    old_event = create(:metadata_event, metadata_event_snapshot: snapshot)

    result = refresh(client: FakeClient.new { raise Faraday::ConnectionFailed, 'offline' })

    assert_equal :stale, result.outcome
    assert MetadataEvent.exists?(old_event.id)
    assert_equal 'stale', result.snapshot.status
  end

  test 'discards a completion superseded by a concurrent refresh' do
    snapshot = create(:metadata_event_snapshot, subject: @subject, generation: 3)
    old_event = create(:metadata_event, metadata_event_snapshot: snapshot)
    client = FakeClient.new do
      snapshot.reload.increment!(:generation)
      @timeline
    end

    result = refresh(client: client)

    assert_equal :superseded, result.outcome
    assert MetadataEvent.exists?(old_event.id)
    refute result.snapshot.metadata_events.exists?(event_type: 'connected')
  end

  test 'uses an anonymous client for a shared public snapshot' do
    client = mock
    client.expects(:get).with("#{@subject.url}/timeline", per_page: 100, page: 1).returns([])
    Octokit::Client.expects(:new).with(auto_paginate: false).returns(client)

    result = MetadataEvents::Refresh.new(subject: @subject).call

    assert_equal :complete, result.outcome
    assert_equal 'public', result.snapshot.scope_key
  end

  test 'uses a viewer token and scope for an authorized private repository' do
    @repository.update!(private: true)
    viewer = create(:user)
    create(:notification, user: viewer, subject_url: @subject.url,
                          repository_full_name: @repository.full_name)

    access_token = viewer.effective_access_token
    viewer.stubs(:effective_access_token).returns(access_token)
    client = mock
    client.expects(:get).with("#{@subject.url}/timeline", per_page: 100, page: 1).returns(@timeline)
    Octokit::Client.expects(:new)
      .with(access_token: access_token, auto_paginate: false)
      .returns(client)

    result = MetadataEvents::Refresh.new(subject: @subject, viewer: viewer).call

    assert_equal :complete, result.outcome
    assert_equal viewer, result.snapshot.viewer
    assert_equal "viewer:#{viewer.id}", result.snapshot.scope_key
    refute MetadataEventSnapshot.exists?(subject: @subject, scope_key: 'public')
  end

  test 'purges public and viewer data when private access is absent' do
    @repository.update!(private: true)
    public_snapshot = create(:metadata_event_snapshot, subject: @subject)
    create(:metadata_event, metadata_event_snapshot: public_snapshot)
    viewer = create(:user, access_token: nil)
    private_snapshot = create(:metadata_event_snapshot, subject: @subject, viewer: viewer,
                                                        scope_key: "viewer:#{viewer.id}")

    result = refresh(client: FakeClient.new { flunk 'must not request GitHub' }, viewer: viewer)

    assert_equal :withheld, result.outcome
    refute MetadataEventSnapshot.exists?(public_snapshot.id)
    refute MetadataEventSnapshot.exists?(private_snapshot.id)
  end

  test 'treats a snapshot deleted during refresh as superseded' do
    snapshot = create(:metadata_event_snapshot, subject: @subject)
    client = FakeClient.new do
      snapshot.destroy!
      @timeline
    end

    result = refresh(client: client)

    assert_equal :superseded, result.outcome
    assert_nil result.snapshot
  end

  test 'purges cached data on an authorization failure' do
    snapshot = create(:metadata_event_snapshot, subject: @subject)
    event = create(:metadata_event, metadata_event_snapshot: snapshot)

    result = refresh(client: FakeClient.new { raise Octokit::Forbidden.new })

    assert_equal :withheld, result.outcome
    refute MetadataEventSnapshot.exists?(snapshot.id)
    refute MetadataEvent.exists?(event.id)
  end

  test 'rejects a non-canonical API origin or path without making a request' do
    snapshot = create(:metadata_event_snapshot, subject: @subject)
    event = create(:metadata_event, metadata_event_snapshot: snapshot)
    @subject.update!(url: 'https://api.github.com.evil.test/repos/octobox/octobox/issues/1')
    client = FakeClient.new { flunk 'must not request an untrusted URL' }

    result = refresh(client: client)

    assert_equal :incomplete, result.outcome
    assert_empty client.pages
    assert MetadataEvent.exists?(event.id)
  end

  test 'reuses a fresh snapshot when not forced' do
    snapshot = create(:metadata_event_snapshot, subject: @subject, refreshed_at: 1.minute.ago)
    client = FakeClient.new { flunk 'must not request GitHub' }

    result = refresh(client: client, force: false)

    assert_equal :fresh, result.outcome
    assert_equal snapshot, result.snapshot
  end

  private

  def refresh(client:, viewer: nil, force: true)
    MetadataEvents::Refresh.new(subject: @subject, viewer: viewer, client: client).call(force: force)
  end

  def ignored_event(index)
    {
      'id' => index + 50_000,
      'event' => 'closed',
      'created_at' => '2026-08-31T10:00:00Z'
    }
  end
end
