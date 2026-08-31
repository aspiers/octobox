# frozen_string_literal: true

require 'test_helper'

class DeploymentActivityFetcherTest < ActiveSupport::TestCase
  setup do
    @subject = create(:subject,
                      url: 'https://api.github.com/repos/octobox/octobox/pulls/42',
                      repository_full_name: 'octobox/octobox',
                      sha: 'a10867b14bb761a232cd80139fbd4c0d33264240')
    @client = Octokit::Client.new(access_token: 'secret', auto_paginate: false)
  end

  test 'combines canonical timeline, deployment, and status payloads' do
    stub_github_deployment_requests

    result = DeploymentActivityFetcher.new(subject: @subject, client: @client).call

    assert result.complete
    assert_equal 2, result.total_count
    assert_equal %w[timeline:DEC_kwDOA-changed timeline:DE_kwDOA-deployed], result.events.pluck('id')

    changed, deployed = result.events
    assert_equal 'deployment_environment_changed', changed['kind']
    assert_equal 'preview/pr-42', changed['environment']
    assert_equal 'success', changed['outcome']
    assert_equal 'release-engineer<script>', changed['actor_login']
    assert_nil changed['actor_url'], 'links outside the configured GitHub hosts must be dropped'
    assert_equal 'https://github.com/octobox/octobox/deployments/preview%2Fpr-42', changed['url']

    assert_equal 'deployed', deployed['kind']
    assert_equal 'success', deployed['outcome']
    assert_equal 'deploy-bot[bot]', deployed['actor_login']
    assert_equal '2026-08-31T09:00:00Z', deployed['occurred_at']
  end

  test 'constructs native deployment links for a configured GHES domain' do
    Octobox.config.stubs(:github_domain).returns('https://github.example.test')
    Octobox.config.stubs(:github_api_prefix).returns('https://github.example.test/api/v3')
    timeline = Oj.load(file_fixture('pull_request_deployment_timeline.json').read)
    deployments = Oj.load(file_fixture('pull_request_deployments.json').read)
    statuses = Oj.load(file_fixture('pull_request_deployment_statuses.json').read)

    stub_request(:get, %r{github\.example\.test/api/v3/repos/octobox/octobox/issues/42/timeline}).
      to_return(status: 200, body: Oj.dump(timeline), headers: { 'Content-Type' => 'application/json' })
    stub_request(:get, %r{github\.example\.test/api/v3/repos/octobox/octobox/deployments\?}).
      to_return(status: 200, body: Oj.dump(deployments), headers: { 'Content-Type' => 'application/json' })
    stub_request(:get, %r{github\.example\.test/api/v3/repos/octobox/octobox/deployments/9001/statuses}).
      to_return(status: 200, body: Oj.dump(statuses), headers: { 'Content-Type' => 'application/json' })

    result = DeploymentActivityFetcher.new(subject: @subject, client: @client).call

    assert result.events.all? { |event| event['url'].start_with?('https://github.example.test/') }
    assert result.events.all? { |event| event['actor_url'].nil? }
  end

  test 'marks a bounded timeline snapshot incomplete and reads the newest pages' do
    full_page = Array.new(100) do |index|
      { id: index, event: 'labeled', created_at: '2026-08-31T08:00:00Z' }
    end
    latest_event = Oj.load(file_fixture('pull_request_deployment_timeline.json').read)[1]
    latest_event['deployment_status'] = Oj.load(file_fixture('pull_request_deployment_statuses.json').read).first

    stub_request(:get, %r{api\.github\.com/repos/octobox/octobox/issues/42/timeline\?.*page=1}).
      to_return(status: 200,
                body: Oj.dump(full_page),
                headers: {
                  'Content-Type' => 'application/json',
                  'Link' => '<https://api.github.com/repos/octobox/octobox/issues/42/timeline?per_page=100&page=8>; rel="last"'
                })
    (4..7).each do |page|
      stub_request(:get, %r{api\.github\.com/repos/octobox/octobox/issues/42/timeline\?.*page=#{page}}).
        to_return(status: 200, body: Oj.dump(full_page), headers: { 'Content-Type' => 'application/json' })
    end
    stub_request(:get, %r{api\.github\.com/repos/octobox/octobox/issues/42/timeline\?.*page=8}).
      to_return(status: 200, body: Oj.dump([latest_event]), headers: { 'Content-Type' => 'application/json' })
    stub_request(:get, %r{api\.github\.com/repos/octobox/octobox/deployments/9001/statuses}).
      to_return(status: 200, body: '[]', headers: { 'Content-Type' => 'application/json' })

    result = DeploymentActivityFetcher.new(subject: @subject, client: @client).call

    refute result.complete
    assert_equal ['timeline:DE_kwDOA-deployed'], result.events.pluck('id')
    assert_not_requested :get, %r{timeline\?.*page=[23](?:&|$)}
  end

  private

  def stub_github_deployment_requests
    stub_request(:get, %r{api\.github\.com/repos/octobox/octobox/issues/42/timeline}).
      to_return(status: 200, body: file_fixture('pull_request_deployment_timeline.json'), headers: { 'Content-Type' => 'application/json' })
    stub_request(:get, %r{api\.github\.com/repos/octobox/octobox/deployments\?}).
      to_return(status: 200, body: file_fixture('pull_request_deployments.json'), headers: { 'Content-Type' => 'application/json' })
    stub_request(:get, %r{api\.github\.com/repos/octobox/octobox/deployments/9001/statuses}).
      to_return(status: 200, body: file_fixture('pull_request_deployment_statuses.json'), headers: { 'Content-Type' => 'application/json' })
  end
end
