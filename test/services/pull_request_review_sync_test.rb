# frozen_string_literal: true
require 'test_helper'

class PullRequestReviewSyncTest < ActiveSupport::TestCase
  include ActionCable::TestHelper

  setup do
    @subject = create(
      :subject,
      url: 'https://api.github.com/repos/octobox/octobox/pulls/42',
      html_url: 'https://github.com/octobox/octobox/pull/42',
      repository_full_name: 'octobox/octobox'
    )
    @timeline = load_json('pull_request_review_timeline.json')
    @comments = load_json('pull_request_review_comments.json')
    @thread_pages = [
      load_json('pull_request_review_threads_page_1.json'),
      load_json('pull_request_review_threads_page_2.json')
    ]
  end

  test 'syncs complete review activity and paginated thread context without N plus one requests' do
    existing = create(
      :comment,
      subject: @subject,
      github_id: 301,
      body: 'stale body',
      activity_kind: nil
    )
    pending_submission = create(
      :comment,
      subject: @subject,
      github_id: 102,
      review_state: 'PENDING'
    )
    pending_comment = create(
      :comment,
      subject: @subject,
      github_id: 303,
      review_github_id: 102,
      activity_kind: 'pull_request_review_comment'
    )
    client = FakeReviewClient.new(@timeline, @comments, @thread_pages)

    assert_no_broadcasts(CommentsChannel.broadcasting_for(@subject)) do
      assert PullRequestReviewSync.new(@subject, client: client).sync
    end

    assert_equal 1, client.timeline_calls
    assert_equal 1, client.comment_calls
    assert_equal 2, client.graphql_calls
    assert_equal 8, @subject.comments.count
    assert_equal 8, @subject.reload.comment_count

    review = @subject.comments.find_by!(github_id: 101, activity_kind: 'pull_request_review')
    assert_equal 'COMMENTED', review.review_state
    assert_equal 'A complete review body', review.body
    assert_equal 'REVIEW_101', review.github_node_id
    assert_equal 'https://github.com/octobox/octobox/pull/42#pullrequestreview-101', review.web_url

    root = existing.reload
    assert_equal 'pull_request_review_comment', root.activity_kind
    assert_equal "Please escape <script>alert('x')</script>", root.body
    assert_equal 101, root.review_github_id
    assert_equal 'THREAD_301', root.thread_github_node_id
    assert_equal false, root.review_context['resolved']
    assert_equal false, root.review_context['outdated']
    assert_equal 'lib/example.rb', root.review_context['path']

    reply = @subject.comments.find_by!(github_id: 302)
    assert_equal 301, reply.reply_to_github_id
    assert_equal 301, reply.review_context['thread_root_github_id']
    assert_equal 'THREAD_301', reply.thread_github_node_id

    outdated = @subject.comments.find_by!(github_id: 304)
    assert_equal true, outdated.review_context['resolved']
    assert_equal true, outdated.review_context['outdated']
    assert_equal true, outdated.review_context['collapsed']
    assert_equal 'THREAD_304', outdated.thread_github_node_id

    dismissal = @subject.comments.find_by!(activity_kind: 'review_dismissed')
    assert_equal 101, dismissal.review_github_id
    assert_equal 'Superseded by a new commit', dismissal.review_context.dig('dismissed_review', 'dismissal_message')

    refute Comment.exists?(pending_submission.id)
    refute Comment.exists?(pending_comment.id)
    assert_nil @subject.comments.find_by(github_id: 102)
    assert_nil @subject.comments.find_by(github_id: 303)
    assert_nil @subject.comments.find_by(github_id: 999)
  end

  test 'preserves a non-empty commented review body when a later response omits it' do
    review = create(
      :comment,
      subject: @subject,
      github_id: 101,
      review_github_id: 101,
      activity_kind: 'pull_request_review',
      review_state: 'COMMENTED',
      body: 'Keep this review body'
    )
    timeline = Marshal.load(Marshal.dump(@timeline))
    timeline.first['body'] = nil
    client = FakeReviewClient.new(timeline, [], [empty_thread_page])

    PullRequestReviewSync.new(@subject, client: client).sync

    assert_equal 'Keep this review body', review.reload.body
  end

  test 'uses REST context and preserves known thread state when GraphQL fails' do
    existing = create(
      :comment,
      subject: @subject,
      github_id: 304,
      activity_kind: 'pull_request_review_comment',
      thread_github_node_id: 'KNOWN_THREAD',
      review_context: {
        'resolved' => true,
        'collapsed' => false,
        'line' => 99,
        'start_line' => 90
      }
    )
    client = FakeReviewClient.new(@timeline, @comments, Faraday::ConnectionFailed.new('offline'))

    assert PullRequestReviewSync.new(@subject, client: client).sync

    existing.reload
    assert_equal 'KNOWN_THREAD', existing.thread_github_node_id
    assert_equal true, existing.review_context['resolved']
    assert_equal false, existing.review_context['collapsed']
    assert_equal true, existing.review_context['outdated']
    assert_equal 'lib/old.rb', existing.review_context['path']
    assert_nil existing.review_context['line']
    assert_nil existing.review_context['start_line']
  end

  test 'reconciles locally retained review comments after a complete snapshot deletes them remotely' do
    deleted = create(
      :comment,
      subject: @subject,
      github_id: 777,
      activity_kind: 'pull_request_review_comment'
    )
    client = FakeReviewClient.new(@timeline, @comments, @thread_pages)

    assert_no_broadcasts(CommentsChannel.broadcasting_for(@subject)) do
      assert PullRequestReviewSync.new(@subject, client: client).sync
    end

    refute Comment.exists?(deleted.id)
  end

  test 'does not reconcile existing rows after a failed review-comment snapshot' do
    existing = create(
      :comment,
      subject: @subject,
      github_id: 777,
      activity_kind: 'pull_request_review_comment'
    )
    client = FakeReviewClient.new(@timeline, Octokit::BadGateway.new, @thread_pages)

    assert_no_broadcasts(CommentsChannel.broadcasting_for(@subject)) do
      refute PullRequestReviewSync.new(@subject, client: client).sync
    end

    assert Comment.exists?(existing.id)
    assert_equal 1, client.timeline_calls
    assert_equal 1, client.comment_calls
    assert_equal 0, client.graphql_calls
  end

  test 'does not mutate rows after Octokit returns an incomplete timeline snapshot' do
    pending = create(:comment, subject: @subject, github_id: 700, review_state: 'PENDING')
    existing = create(
      :comment,
      subject: @subject,
      github_id: 777,
      activity_kind: 'pull_request_review_comment'
    )
    client = octokit_snapshot_client(timeline_next: Object.new)
    client.expects(:pull_request_comments).never

    assert_no_broadcasts(CommentsChannel.broadcasting_for(@subject)) do
      refute PullRequestReviewSync.new(@subject, client: client).sync
    end

    assert Comment.exists?(pending.id)
    assert Comment.exists?(existing.id)
    assert_equal 2, @subject.comments.count
  end

  test 'does not mutate or reconcile rows after Octokit returns incomplete review comments' do
    pending = create(:comment, subject: @subject, github_id: 700, review_state: 'PENDING')
    existing = create(
      :comment,
      subject: @subject,
      github_id: 777,
      activity_kind: 'pull_request_review_comment'
    )
    client = octokit_snapshot_client(comments_next: Object.new)

    assert_no_broadcasts(CommentsChannel.broadcasting_for(@subject)) do
      refute PullRequestReviewSync.new(@subject, client: client).sync
    end

    assert Comment.exists?(pending.id)
    assert Comment.exists?(existing.id)
    assert_equal 2, @subject.comments.count
  end

  test 'does not broadcast when a complete snapshot makes no changes' do
    PullRequestReviewSync.new(
      @subject,
      client: FakeReviewClient.new(@timeline, @comments, @thread_pages)
    ).sync

    assert_no_broadcasts(CommentsChannel.broadcasting_for(@subject)) do
      assert PullRequestReviewSync.new(
        @subject,
        client: FakeReviewClient.new(@timeline, @comments, @thread_pages)
      ).sync
    end
  end

  test 'serializes review synchronization with the subject row lock' do
    @subject.expects(:with_lock).once.yields.returns([true, false])
    client = FakeReviewClient.new(@timeline, @comments, @thread_pages)

    assert PullRequestReviewSync.new(@subject, client: client).sync
  end

  test 'does not reconcile existing rows or expose response content after a timeline failure' do
    existing = create(:comment, subject: @subject, github_id: 500, body: 'existing review data')
    error = Octokit::BadGateway.new(
      status: 502,
      body: 'private response body',
      response_headers: {authorization: 'Bearer secret-token'}
    )
    client = FakeReviewClient.new(error, @comments, @thread_pages)
    logged = []
    Rails.logger.stubs(:warn).with { |message| logged << message; true }

    refute PullRequestReviewSync.new(@subject, client: client).sync

    assert_equal 1, client.timeline_calls
    assert_equal 0, client.comment_calls
    assert_equal 'existing review data', existing.reload.body
    assert_equal 1, @subject.comments.count
    event = JSON.parse(logged.fetch(0))
    assert_equal 'pull_request_review_timeline', event['operation']
    assert_equal @subject.url, event['subject_url']
    assert_equal 'Octokit::BadGateway', event['exception']
    refute_includes logged.first, 'private response body'
    refute_includes logged.first, 'secret-token'
  end

  test 'links review request events without a native URL to the pull request' do
    client = FakeReviewClient.new(@timeline, @comments, @thread_pages)

    PullRequestReviewSync.new(@subject, client: client).sync

    request = @subject.comments.find_by!(activity_kind: 'review_requested')
    removal = @subject.comments.find_by!(activity_kind: 'review_request_removed')
    assert_equal @subject.html_url, request.web_url
    assert_equal @subject.html_url, removal.web_url
  end

  test 'stores review comment reactions and keeps them when a response omits the summary' do
    reply = create(
      :comment,
      subject: @subject,
      github_id: 302,
      activity_kind: 'pull_request_review_comment',
      reactions: {'rocket' => 2}
    )
    comments = Marshal.load(Marshal.dump(@comments))
    comments.find { |comment| comment['id'] == 301 }['reactions'] = {'total_count' => 2, 'eyes' => 2, 'heart' => 0}
    client = FakeReviewClient.new(@timeline, comments, @thread_pages)

    assert PullRequestReviewSync.new(@subject, client: client).sync

    assert_equal({'eyes' => 2}, @subject.comments.find_by!(github_id: 301).reactions)
    assert_equal({'rocket' => 2}, reply.reload.reactions)
  end

  private

  def load_json(name)
    Oj.load(file_fixture(name).read)
  end

  def empty_thread_page
    {
      'data' => {
        'repository' => {
          'pullRequest' => {
            'reviewThreads' => {'nodes' => [], 'pageInfo' => {'hasNextPage' => false}}
          }
        }
      }
    }
  end

  def octokit_snapshot_client(timeline_next: nil, comments_next: nil)
    timeline = @timeline
    comments = @comments
    response_class = Struct.new(:rels)
    timeline_response = response_class.new({next: timeline_next})
    comments_response = response_class.new({next: comments_next})
    client = Octokit::Client.new(auto_paginate: true)

    client.define_singleton_method(:issue_timeline) do |_repository, _number|
      @last_response = timeline_response
      timeline
    end
    client.define_singleton_method(:pull_request_comments) do |_repository, _number|
      @last_response = comments_response
      comments
    end
    client
  end

  class FakeReviewClient
    attr_reader :timeline_calls, :comment_calls, :graphql_calls

    def initialize(timeline, comments, thread_pages)
      @timeline = timeline
      @comments = comments
      @thread_pages = thread_pages
      @timeline_calls = 0
      @comment_calls = 0
      @graphql_calls = 0
    end

    def issue_timeline(repository, number)
      @timeline_calls += 1
      assert_request(repository, number)
      raise @timeline if @timeline.is_a?(Exception)
      @timeline
    end

    def pull_request_comments(repository, number)
      @comment_calls += 1
      assert_request(repository, number)
      raise @comments if @comments.is_a?(Exception)
      @comments
    end

    def post(path, body)
      @graphql_calls += 1
      raise @thread_pages if @thread_pages.is_a?(Exception)
      raise 'wrong GraphQL path' unless path == 'graphql'
      raise 'query omitted reviewThreads' unless body['query'].include?('reviewThreads')
      variables = body['variables']
      raise 'wrong variables' unless variables['owner'] == 'octobox' && variables['name'] == 'octobox' && variables['number'] == 42
      @thread_pages.fetch(@graphql_calls - 1)
    end

    private

    def assert_request(repository, number)
      raise 'wrong repository' unless repository == 'octobox/octobox'
      raise 'wrong pull number' unless number == 42
    end
  end
end
