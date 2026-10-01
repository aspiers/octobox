# frozen_string_literal: true
require 'test_helper'

class SubjectReactionsTest < ActiveSupport::TestCase
  setup do
    stub_include_comments(value: false)
  end

  test 'sync stores normalized subject reaction counts' do
    remote_subject = load_subject_fixture
    remote_subject['reactions'] = {'total_count' => 4, '+1' => 3, 'heart' => 1, 'eyes' => 0}
    subject = create(:subject, url: remote_subject['url'])

    subject.sync(remote_subject)

    assert_equal({'+1' => 3, 'heart' => 1}, subject.reload.reactions)
  end

  test 'sync preserves stored reactions when the response has no summary' do
    remote_subject = load_subject_fixture
    subject = create(:subject, url: remote_subject['url'], reactions: {'heart' => 2})

    subject.sync(remote_subject)

    assert_equal({'heart' => 2}, subject.reload.reactions)
  end

  test 'sync clears reactions from an authoritative empty summary' do
    remote_subject = load_subject_fixture
    remote_subject['reactions'] = {'total_count' => 0}
    subject = create(:subject, url: remote_subject['url'], reactions: {'heart' => 2})

    subject.sync(remote_subject)

    assert_equal({}, subject.reload.reactions)
  end

  test 'issue comment sync stores normalized reaction counts from the GitHub response' do
    subject = create(:subject, url: 'https://api.github.com/repos/octobox/octobox/issues/56')
    subject.stubs(:github_client).returns(Octokit::Client.new)
    stub_request(:get, "#{subject.url}/comments")
      .with(query: {per_page: '100', since: nil})
      .to_return(status: 200, body: file_fixture('reaction_comments.json'),
                 headers: {'Content-Type' => 'application/json'})

    subject.update_comments

    comment = subject.comments.find_by!(github_id: 9001)
    assert_equal({'+1' => 3, 'hooray' => 1, 'heart' => 1}, comment.reactions)
    assert_equal 'issue_comment', comment.activity_kind
  end

  test 'issue comment sync updates bodies and reactions of stored comments' do
    subject = create(:subject)
    kept = create(:comment, subject: subject, github_id: 9001, activity_kind: 'issue_comment',
                            body: 'old body', reactions: {'rocket' => 2})
    stub_issue_comments(subject, reaction_comments)

    subject.update_comments

    assert_equal 'This works for me.', kept.reload.body
    assert_equal({'+1' => 3, 'hooray' => 1, 'heart' => 1}, kept.reactions)
  end

  test 'incremental issue comment sync keeps comments and reactions it did not receive' do
    subject = create(:subject)
    existing = create(:comment, subject: subject, github_id: 9004, activity_kind: 'issue_comment',
                                reactions: {'rocket' => 2})
    stub_issue_comments(subject, reaction_comments)

    subject.update_comments

    assert_equal({'rocket' => 2}, existing.reload.reactions)
    assert subject.comments.exists?(github_id: 9001)
  end

  test 'issue comment webhook stores the payload reactions' do
    repository = create(:repository, github_id: 123, private: false)
    subject = create(:subject, repository: repository)
    subject.stubs(:github_client).returns(Object.new)

    subject.sync_issue_comment_event(reaction_comments.first, action: 'edited', repository_github_id: 123)

    comment = subject.comments.find_by!(github_id: 9001)
    assert_equal 'hubot', comment.author
    assert_equal({'+1' => 3, 'hooray' => 1, 'heart' => 1}, comment.reactions)
    assert_equal 1, subject.reload.comment_count
  end

  test 'deleted comment webhook removes a comment after repository authorization' do
    repository = create(:repository, github_id: 123, private: false)
    subject = create(:subject, repository: repository)
    subject.stubs(:github_client).returns(Object.new)
    comment = create(:comment, subject: subject, github_id: 9001)

    subject.sync_issue_comment_event({'id' => 9001}, action: 'deleted', repository_github_id: 123)

    refute Comment.exists?(comment.id)
  end

  test 'private comment webhook cannot change shared data without an app installation' do
    repository = create(:repository, github_id: 123, private: true)
    subject = create(:subject, repository: repository)
    comment = create(:comment, subject: subject, github_id: 9001)

    subject.sync_issue_comment_event({'id' => 9001}, action: 'deleted', repository_github_id: 123)

    assert Comment.exists?(comment.id)
  end

  private

  def load_subject_fixture
    Oj.load(file_fixture('subject_56.json').read)
  end

  def reaction_comments
    Oj.load(file_fixture('reaction_comments.json').read)
  end

  def stub_issue_comments(subject, items)
    subject.stubs(:github_client).returns(Object.new)
    subject.stubs(:download_comments).returns(GithubPreviewFetcher::Result.new(items: items, complete: true))
  end
end
