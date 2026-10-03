# frozen_string_literal: true

require 'test_helper'

class UserTokenRefreshConcurrencyTest < ActiveSupport::TestCase
  self.use_transactional_tests = false

  setup do
    @login = "refresh-concurrency-#{SecureRandom.hex(6)}"
    @user = create(
      :user,
      github_login: @login,
      app_token: 'old-access-token',
      app_refresh_token: 'old-refresh-token',
      app_token_expires_at: 1.minute.from_now
    )
    Octobox.config.stubs(:github_app_client_id).returns('app-client-id')
    Octobox.config.stubs(:github_app_client_secret).returns('app-client-secret')
    Octobox.config.stubs(:github_domain).returns('https://github.example.com')
    stub_request(:post, 'https://github.example.com/login/oauth/access_token').to_return do
      sleep 0.1
      {
        status: 200,
        body: {
          access_token: 'new-access-token',
          refresh_token: 'new-refresh-token',
          expires_in: 28_800
        }.to_json,
        headers: {'Content-Type' => 'application/json'}
      }
    end
  end

  teardown do
    User.find_by(github_login: @login)&.destroy!
  end

  test 'concurrent callers perform one refresh grant' do
    ready = Queue.new
    start = Queue.new
    threads = 2.times.map do
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          stale_user = User.find(@user.id)
          ready << true
          start.pop
          stale_user.app_installation_client.access_token
        end
      end
    end
    2.times { ready.pop }
    2.times { start << true }

    assert_equal ['new-access-token', 'new-access-token'], threads.map(&:value)
    assert_requested :post,
                     'https://github.example.com/login/oauth/access_token',
                     times: 1
  end
end
