# frozen_string_literal: true
require 'test_helper'

class GithubPreviewFetcherTest < ActiveSupport::TestCase
  class RecordingLogger
    attr_reader :messages

    def initialize
      @messages = []
    end

    def warn(message)
      @messages << message
    end
  end

  setup do
    @client = Octokit::Client.new
    @logger = RecordingLogger.new
    @fetcher = GithubPreviewFetcher.new(@client, logger: @logger)
  end

  test 'fetches every linked page with reaction media and API version headers' do
    first_url = 'https://api.github.com/repos/octobox/octobox/issues/56/comments'
    second_url = 'https://api.github.com/repos/octobox/octobox/issues/56/comments?page=2'
    headers = {
      'Accept' => GithubPreviewFetcher::ACCEPT,
      'X-GitHub-Api-Version' => GithubPreviewFetcher::API_VERSION
    }

    stub_request(:get, first_url).with(query: {per_page: '100'}, headers: headers).to_return(
      status: 200,
      body: [{id: 1}].to_json,
      headers: {
        'Content-Type' => 'application/json',
        'Link' => "<#{second_url}>; rel=\"next\""
      }
    )
    stub_request(:get, second_url).with(query: {page: '2', per_page: '100'}, headers: headers).to_return(
      status: 200,
      body: [{id: 2}].to_json,
      headers: {'Content-Type' => 'application/json'}
    )

    result = @fetcher.collection(first_url)

    assert result.complete?
    assert_equal [1, 2], result.items.map(&:id)
  end

  test 'applies incremental parameters to the first page and follows linked pages' do
    first_url = 'https://api.github.com/repos/octobox/octobox/issues/56/comments'
    second_url = 'https://api.github.com/repos/octobox/octobox/issues/56/comments?page=2&since=2026-08-30T10%3A00%3A00Z'
    stub_request(:get, first_url).with(
      query: {per_page: '100', since: '2026-08-30T10:00:00Z'}
    ).to_return(
      status: 200,
      body: [{id: 1}].to_json,
      headers: {'Content-Type' => 'application/json', 'Link' => "<#{second_url}>; rel=\"next\""}
    )
    stub_request(:get, second_url).with(
      query: {page: '2', per_page: '100', since: '2026-08-30T10:00:00Z'}
    ).to_return(status: 200, body: [{id: 2}].to_json, headers: {'Content-Type' => 'application/json'})

    result = @fetcher.collection(first_url, params: {since: '2026-08-30T10:00:00Z'})

    assert result.complete?
    assert_equal [1, 2], result.items.map(&:id)
  end

  test 'returns fetched pages as incomplete when a later page is forbidden' do
    first_url = 'https://api.github.com/repos/octobox/octobox/issues/56/comments'
    second_url = 'https://api.github.com/repos/octobox/octobox/issues/56/comments?page=2'
    stub_request(:get, first_url).with(query: {per_page: '100'}).to_return(
      status: 200,
      body: [{id: 1}].to_json,
      headers: {
        'Content-Type' => 'application/json',
        'Link' => "<#{second_url}>; rel=\"next\""
      }
    )
    stub_request(:get, second_url).with(query: {page: '2', per_page: '100'}).to_return(
      status: 403,
      body: '{"message":"private response body"}',
      headers: {
        'Content-Type' => 'application/json',
        'Authorization' => 'Bearer secret-token',
        'X-RateLimit-Limit' => '5000',
        'X-RateLimit-Remaining' => '0',
        'X-RateLimit-Reset' => '1789123456'
      }
    )

    result = @fetcher.collection(
      first_url,
      operation: 'issue_comments',
      subject_url: 'https://api.github.com/repos/octobox/octobox/issues/56'
    )

    refute result.complete?
    assert_equal [1], result.items.map(&:id)
    assert_equal 1, @logger.messages.length
    message = @logger.messages.first
    event = JSON.parse(message)
    assert_equal 'github_preview_fetch_failed', event['event']
    assert_equal 'issue_comments', event['operation']
    assert_equal 'https://api.github.com/repos/octobox/octobox/issues/56', event['subject_url']
    assert_equal 'Octokit::Forbidden', event['exception']
    assert_equal 403, event['status']
    assert_equal({'x-ratelimit-limit' => '5000', 'x-ratelimit-remaining' => '0', 'x-ratelimit-reset' => '1789123456'}, event['rate_limit'])
    refute_includes message, 'private response body'
    refute_includes message, 'secret-token'
    refute_includes message, 'Authorization'
  end

  test 'logs server failures without failing the collection sync' do
    url = 'https://api.github.com/repos/octobox/octobox/issues/56/comments'
    stub_request(:get, url).with(query: {per_page: '100'}).to_return(
      status: 503,
      body: 'private server response',
      headers: {'Content-Type' => 'text/plain', 'Retry-After' => '30'}
    )

    result = @fetcher.collection(url, operation: 'issue_comments')

    refute result.complete?
    assert_empty result.items
    assert_equal 1, @logger.messages.length
    message = @logger.messages.first
    event = JSON.parse(message)
    assert_equal 'Octokit::ServiceUnavailable', event['exception']
    assert_equal 503, event['status']
    assert_equal({'retry-after' => '30'}, event['rate_limit'])
    refute_includes message, 'private server response'
  end

  test 'logs network failures without exposing the exception message' do
    url = 'https://api.github.com/repos/octobox/octobox/issues/56/comments'
    stub_request(:get, url).with(query: {per_page: '100'})
      .to_raise(Faraday::ConnectionFailed.new('private network detail'))

    result = @fetcher.collection(url, operation: 'issue_comments')

    refute result.complete?
    assert_empty result.items
    message = @logger.messages.fetch(0)
    event = JSON.parse(message)
    assert_equal 'Faraday::ConnectionFailed', event['exception']
    refute_includes message, 'private network detail'
  end

  test 'stops at the page bound and marks the collection incomplete' do
    base_url = 'https://api.github.com/repos/octobox/octobox/issues/56/comments'
    GithubPreviewFetcher::MAX_PAGES.times do |index|
      page = index + 1
      request_url = page == 1 ? base_url : "#{base_url}?page=#{page}"
      next_url = "#{base_url}?page=#{page + 1}"
      query = {per_page: '100'}
      query[:page] = page.to_s unless page == 1
      stub_request(:get, request_url).with(query: query).to_return(
        status: 200,
        body: [{id: page}].to_json,
        headers: {
          'Content-Type' => 'application/json',
          'Link' => "<#{next_url}>; rel=\"next\""
        }
      )
    end

    result = @fetcher.collection(base_url)

    refute result.complete?
    assert_equal GithubPreviewFetcher::MAX_PAGES, result.items.length
  end
end
