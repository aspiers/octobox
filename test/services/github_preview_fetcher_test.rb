# frozen_string_literal: true
require 'test_helper'

class GithubPreviewFetcherTest < ActiveSupport::TestCase
  setup do
    @client = Octokit::Client.new
    @fetcher = GithubPreviewFetcher.new(@client)
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
      status: 403, body: '{}', headers: {'Content-Type' => 'application/json'}
    )

    result = @fetcher.collection(first_url)

    refute result.complete?
    assert_equal [1], result.items.map(&:id)
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
