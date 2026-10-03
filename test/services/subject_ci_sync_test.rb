# frozen_string_literal: true

require "test_helper"

class SubjectCiSyncTest < ActiveSupport::TestCase
  SHA = "a10867b14bb761a232cd80139fbd4c0d33264240"
  REPOSITORY = "octobox/octobox"
  STATUS_PATH = "repos/#{REPOSITORY}/statuses/#{SHA}"
  CHECK_RUN_PATH = "repos/#{REPOSITORY}/commits/#{SHA}/check-runs"
  CHECK_SUITE_PATH = "repos/#{REPOSITORY}/commits/#{SHA}/check-suites"

  class FakeClient
    attr_reader :requests
    attr_accessor :combined_status_response

    def initialize
      @responses = {}
      @requests = []
      @combined_status_response = { "state" => "success", "statuses" => [{}] }
    end

    def respond_with(path, page, response)
      @responses[[path, page]] = response
    end

    def combined_status(*)
      raise combined_status_response if combined_status_response.is_a?(Exception)

      combined_status_response
    end

    def get(path, options)
      @requests << [path, options]
      response = @responses.fetch([path, options.fetch(:page)]) do
        if path.end_with?("check-runs")
          { "total_count" => 0, "check_runs" => [] }
        elsif path.end_with?("check-suites")
          { "total_count" => 0, "check_suites" => [] }
        else
          []
        end
      end
      raise response if response.is_a?(Exception)

      response
    end
  end

  setup do
    @subject = create(
      :subject,
      url: "https://api.github.com/repos/#{REPOSITORY}/pulls/123",
      repository_full_name: REPOSITORY,
      sha: SHA,
      status: "pending"
    )
    @client = FakeClient.new
  end

  test "fetches complete status and check-run snapshots and persists their context" do
    statuses = load_json_fixture("ci_statuses.json")
    first_page = Array.new(100) do |index|
      statuses.first.merge(
        "id" => 10_000 + index,
        "context" => "continuous-integration/job-#{index}"
      )
    end
    @client.respond_with(STATUS_PATH, 1, first_page)
    @client.respond_with(STATUS_PATH, 2, [statuses.second])
    @client.respond_with(CHECK_RUN_PATH, 1, load_json_fixture("ci_check_runs.json"))

    SubjectCiSync.call(@subject, @client)

    assert_equal "success", @subject.reload.status
    assert_equal 101, @subject.ci_activities.where(kind: "status").count
    assert_equal 2, @subject.ci_activities.where(kind: "check_run").count
    assert_includes @client.requests, [STATUS_PATH, { per_page: 100, page: 2 }]

    status = @subject.ci_activities.find_by!(github_id: 7002)
    assert_equal "continuous-integration/example", status.name
    assert_equal "All tests passed", status.description
    assert_equal "https://ci.example.test/builds/7002", status.target_url

    check_run = @subject.ci_activities.find_by!(github_id: 8001)
    assert_equal "Ruby tests", check_run.name
    assert_equal "success", check_run.conclusion
    assert_equal "Test suite passed", check_run.description
    assert_equal "214 tests passed", check_run.summary
    assert_equal "GitHub Actions", check_run.app_name
    assert_equal 8100, check_run.check_suite_id
    assert_equal "https://github.com/octobox/octobox/actions/runs/8001", check_run.target_url
  end

  test "persists check suites with native GitHub links" do
    @client.respond_with(
      CHECK_SUITE_PATH,
      1,
      {
        "total_count" => 1,
        "check_suites" => [{
          "id" => 8100,
          "head_sha" => SHA,
          "status" => "completed",
          "conclusion" => "success",
          "app" => {"name" => "GitHub Actions"},
          "created_at" => "2026-08-31T10:00:00Z",
          "updated_at" => "2026-08-31T10:05:00Z",
          "latest_check_runs_count" => 2
        }]
      }
    )

    SubjectCiSync.call(@subject, @client)

    suite = @subject.ci_activities.find_by!(kind: "check_suite", github_id: 8100)
    assert_equal "GitHub Actions check suite", suite.name
    assert_equal "success", suite.conclusion
    assert_equal "https://github.com/octobox/octobox/commit/#{SHA}/checks?check_suite_id=8100", suite.target_url
  end

  test "keeps distinct status updates and check attempts while repeated syncs stay idempotent" do
    @client.respond_with(STATUS_PATH, 1, load_json_fixture("ci_statuses.json"))
    @client.respond_with(CHECK_RUN_PATH, 1, load_json_fixture("ci_check_runs.json"))

    2.times { SubjectCiSync.call(@subject, @client) }

    assert_equal 4, @subject.ci_activities.count
    assert_equal [7001, 7002], @subject.ci_activities.where(kind: "status").order(:github_id).pluck(:github_id)
    assert_equal [8001, 8002], @subject.ci_activities.where(kind: "check_run").order(:github_id).pluck(:github_id)
  end

  test "updates mutable records and removes stale entries after a complete source snapshot" do
    create(:ci_activity, subject: @subject, kind: "status", github_id: 6999, head_sha: "old-sha")
    create(
      :ci_activity,
      subject: @subject,
      kind: "status",
      github_id: 7001,
      state: "pending",
      github_updated_at: Time.zone.parse("2026-08-31 09:00:00 UTC")
    )
    retained_check = create(:ci_activity, subject: @subject, kind: "check_run", github_id: 8999, head_sha: "old-sha")
    @client.respond_with(STATUS_PATH, 1, [load_json_fixture("ci_statuses.json").first])
    @client.respond_with(CHECK_RUN_PATH, 1, Octokit::Forbidden.new)

    SubjectCiSync.call(@subject, @client)

    assert_equal [7001], @subject.ci_activities.where(kind: "status").pluck(:github_id)
    assert_equal "failure", @subject.ci_activities.find_by!(github_id: 7001).state
    assert CiActivity.exists?(retained_check.id)
  end

  test "does not change records when a later status page is rate limited" do
    retained = create(:ci_activity, subject: @subject, kind: "status", github_id: 6999, state: "success")
    first_page = Array.new(100) do |index|
      {
        "id" => 20_000 + index,
        "context" => "job-#{index}",
        "state" => "pending"
      }
    end
    @client.respond_with(STATUS_PATH, 1, first_page)
    @client.respond_with(STATUS_PATH, 2, Octokit::TooManyRequests.new)

    SubjectCiSync.call(@subject, @client)

    assert CiActivity.exists?(retained.id)
    assert_equal [6999], @subject.ci_activities.where(kind: "status").pluck(:github_id)
  end

  test "drops unsafe target URLs before persistence" do
    unsafe_status = load_json_fixture("ci_statuses.json").first.merge("target_url" => "javascript:alert(1)")
    unsafe_check_runs = load_json_fixture("ci_check_runs.json")
    unsafe_check_runs["check_runs"].first["details_url"] = "https://secret@ci.example.test/run"
    @client.respond_with(STATUS_PATH, 1, [unsafe_status])
    @client.respond_with(CHECK_RUN_PATH, 1, unsafe_check_runs)

    SubjectCiSync.call(@subject, @client)

    assert_nil @subject.ci_activities.find_by!(github_id: 7001).target_url
    assert_nil @subject.ci_activities.find_by!(github_id: 8001).target_url
  end

  test "aggregate status retains structured logging for server and network failures" do
    events = []
    Rails.logger.stubs(:warn).with do |message|
      events << JSON.parse(message)
      true
    end

    [Octokit::InternalServerError.new, Faraday::ConnectionFailed.new("private error details")].each do |error|
      @client.combined_status_response = error
      SubjectCiSync.call(@subject, @client)
    end

    assert_equal "pending", @subject.reload.status
    assert_equal 2, events.length
    events.each do |event|
      assert_equal "github_preview_fetch_failed", event.fetch("event")
      assert_equal "combined_status", event.fetch("operation")
      assert_equal @subject.url, event.fetch("subject_url")
      refute_includes event.to_json, "private error details"
    end
  end

  private

  def load_json_fixture(filename)
    Oj.load(file_fixture(filename).read)
  end
end
