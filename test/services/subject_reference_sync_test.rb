# frozen_string_literal: true

require "test_helper"

class SubjectReferenceSyncTest < ActiveSupport::TestCase
  TARGET_REPOSITORY = "example/target"
  TIMELINE_URL = "https://api.github.com/repos/example/target/issues/99/timeline"
  COMMIT_URL = "https://api.github.com/repos/example/source/commits/0123456789abcdef0123456789abcdef01234567"

  class FakeClient
    attr_reader :requests

    def initialize
      @responses = {}
      @requests = []
    end

    def respond_with(url, response, page: nil)
      @responses[[url, page]] = response
    end

    def get(url, options = {})
      @requests << [url, options]
      response = @responses.fetch([url, options[:page]]) { @responses.fetch([url, nil]) }
      response = response.call if response.respond_to?(:call)
      raise response if response.is_a?(Exception)

      response
    end
  end

  setup do
    @repository = create(:repository, full_name: TARGET_REPOSITORY, private: false)
    @subject = create(
      :subject,
      repository: @repository,
      repository_full_name: TARGET_REPOSITORY,
      url: "https://api.github.com/repos/example/target/issues/99",
      html_url: "https://github.com/example/target/issues/99"
    )
    @client = FakeClient.new
    @timeline = load_json_fixture("reference_timeline.json")
    @commit = load_json_fixture("reference_commit.json")
    @client.respond_with(COMMIT_URL, @commit)
  end

  test "fetches every timeline page with the preview and API version headers" do
    first_page = @timeline + Array.new(SubjectReferenceSync::PER_PAGE - @timeline.length) do |index|
      { "id" => 50_000 + index, "event" => "labeled", "created_at" => "2026-08-30T12:00:00Z" }
    end
    @client.respond_with(TIMELINE_URL, first_page, page: 1)
    @client.respond_with(TIMELINE_URL, [], page: 2)

    assert SubjectReferenceSync.call(@subject, @client)

    timeline_requests = @client.requests.select { |url, _options| url == TIMELINE_URL }
    assert_equal [1, 2], timeline_requests.map { |_url, options| options[:page] }
    timeline_requests.each do |_url, options|
      assert_equal SubjectReferenceSync::TIMELINE_ACCEPT, options[:accept]
      assert_equal SubjectReferenceSync::API_VERSION, options.dig(:headers, "X-GitHub-Api-Version")
    end
  end

  test "persists only cross-reference, mention, and commit-reference context" do
    @client.respond_with(TIMELINE_URL, @timeline, page: 1)

    assert SubjectReferenceSync.call(@subject, @client)

    assert_equal 3, @subject.reference_activities.count
    assert_equal %w[cross_reference commit_reference mention],
                 @subject.reference_activities.chronological.pluck(:activity_type)

    issue = @subject.reference_activities.find_by!(activity_type: "cross_reference")
    assert_equal "issue", issue.source_type
    assert_equal "example/source", issue.source_repository_full_name
    assert_equal 41, issue.source_number
    assert_equal "The parser calls the old endpoint", issue.source_title
    assert_equal "alice", issue.source_author
    assert_includes issue.body_snippet, "reproduces the bug"
    assert_equal "https://github.com/example/source/issues/41", issue.native_url

    commit = @subject.reference_activities.find_by!(activity_type: "commit_reference")
    assert_equal "commit", commit.source_type
    assert_equal "0123456789abcdef0123456789abcdef01234567", commit.source_identifier
    assert_equal "Fix parser fallback", commit.source_title
    assert_equal "bob", commit.source_author
    assert_includes commit.body_snippet, "explains why"
    assert_equal @commit["html_url"], commit.native_url

    mention = @subject.reference_activities.find_by!(activity_type: "mention")
    assert_equal "pull_request", mention.source_type
    assert_equal 43, mention.source_number
    refute @subject.reference_activities.where(source_title: "pending private review text").exists?
  end

  test "reconciles a complete snapshot and keeps stable rows additive" do
    @client.respond_with(TIMELINE_URL, @timeline, page: 1)
    SubjectReferenceSync.call(@subject, @client)
    retained = @subject.reference_activities.find_by!(activity_type: "cross_reference")
    removed = @subject.reference_activities.find_by!(activity_type: "mention")

    @client.respond_with(TIMELINE_URL, [@timeline.first], page: 1)
    SubjectReferenceSync.call(@subject, @client)

    assert_equal retained.id, @subject.reference_activities.find_by!(activity_type: "cross_reference").id
    refute ReferenceActivity.exists?(removed.id)
    assert_equal 1, @subject.reference_activities.count
  end

  test "does not modify stored activity after an incomplete or rate-limited snapshot" do
    existing = create(:reference_activity, subject: @subject, source_title: "keep this")
    full_page = Array.new(SubjectReferenceSync::PER_PAGE) do |index|
      { "id" => 60_000 + index, "event" => "labeled", "created_at" => "2026-08-30T12:00:00Z" }
    end
    @client.respond_with(TIMELINE_URL, full_page, page: 1)
    @client.respond_with(TIMELINE_URL, Faraday::ConnectionFailed.new("rate limited"), page: 2)

    refute SubjectReferenceSync.call(@subject, @client)

    assert_equal [existing], @subject.reference_activities.reload.to_a
    assert_nil @subject.reload.reference_activities_sync_started_at
  end

  test "does not persist a stale snapshot after the subject changes" do
    @client.respond_with(TIMELINE_URL, -> {
      @subject.touch
      @timeline
    }, page: 1)

    refute SubjectReferenceSync.call(@subject, @client)

    assert_empty @subject.reference_activities.reload
  end

  test "does not let an older concurrent snapshot replace a newer one" do
    @subject.update_column(:reference_activities_sync_started_at, 1.minute.from_now)
    @client.respond_with(TIMELINE_URL, @timeline, page: 1)

    refute SubjectReferenceSync.call(@subject, @client)

    assert_empty @subject.reference_activities.reload
  end

  test "withholds target-private activity, purges old shared rows, and makes no request" do
    @repository.update!(private: true)
    create(:reference_activity, subject: @subject, source_title: "private activity")

    refute SubjectReferenceSync.call(@subject, @client)

    assert_empty @subject.reference_activities.reload
    assert_empty @client.requests
  end

  test "does not persist references sourced from a private repository" do
    private_event = Marshal.load(Marshal.dump(@timeline.first))
    private_event["source"]["issue"]["repository"]["private"] = true
    @client.respond_with(TIMELINE_URL, [private_event], page: 1)

    assert SubjectReferenceSync.call(@subject, @client)

    assert_empty @subject.reference_activities.reload
  end

  test "treats a snapshot over the activity bound as incomplete" do
    events = Array.new(SubjectReferenceSync::MAX_ACTIVITIES + 1) do |index|
      @timeline.first.deep_dup.tap do |event|
        event["source"]["issue"]["number"] = index + 1
        event["source"]["issue"]["html_url"] = "https://github.com/example/source/issues/#{index + 1}"
      end
    end
    events.each_slice(SubjectReferenceSync::PER_PAGE).with_index(1) do |page, number|
      @client.respond_with(TIMELINE_URL, page, page: number)
    end
    existing = create(:reference_activity, subject: @subject)

    refute SubjectReferenceSync.call(@subject, @client)
    assert_equal [existing], @subject.reference_activities.reload.to_a
  end

  private

  def load_json_fixture(name)
    Oj.load(file_fixture(name).read)
  end
end
