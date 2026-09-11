# frozen_string_literal: true

require 'test_helper'

class GithubAppUserTokenRefresherTest < ActiveSupport::TestCase
  setup do
    Octobox.config.stubs(:github_app_client_id).returns('app-client-id')
    Octobox.config.stubs(:github_app_client_secret).returns('app-client-secret')
    Octobox.config.stubs(:github_domain).returns('https://github.example.com')
  end

  test 'exchanges a refresh grant for rotated credentials' do
    stub_refresh_response(
      access_token: 'new-access-token',
      expires_in: 28_800,
      refresh_token: 'new-refresh-token'
    )

    credentials = GithubAppUserTokenRefresher.new(refresh_token: 'old-refresh-token').refresh

    assert_equal 'new-access-token', credentials.access_token
    assert_equal 'new-refresh-token', credentials.refresh_token
    assert_in_delta 8.hours.from_now.to_i, credentials.expires_at.to_i, 2
  end

  test 'rejects a successful response without a rotated refresh token' do
    stub_refresh_response(access_token: 'new-access-token', expires_in: 28_800)

    error = assert_raises(GithubAppUserTokenRefresher::InvalidResponse) do
      GithubAppUserTokenRefresher.new(refresh_token: 'secret-refresh-token').refresh
    end

    assert_equal 'GitHub refresh response missing refresh_token', error.message
    refute_includes error.message, 'secret-refresh-token'
  end

  test 'rejects a successful response without an expiry' do
    stub_refresh_response(
      access_token: 'new-access-token',
      refresh_token: 'new-refresh-token'
    )

    error = assert_raises(GithubAppUserTokenRefresher::InvalidResponse) do
      GithubAppUserTokenRefresher.new(refresh_token: 'old-refresh-token').refresh
    end

    assert_equal 'GitHub refresh response missing expiry', error.message
  end

  private

  def stub_refresh_response(payload)
    stub_request(:post, 'https://github.example.com/login/oauth/access_token').with(
      headers: {'Accept' => 'application/json'},
      body: hash_including(
        'client_id' => 'app-client-id',
        'client_secret' => 'app-client-secret',
        'grant_type' => 'refresh_token',
        'refresh_token' => /refresh-token/
      )
    ).to_return(
      status: 200,
      body: payload.to_json,
      headers: {'Content-Type' => 'application/json'}
    )
  end
end
