# frozen_string_literal: true
require 'test_helper'

class SessionsControllerTest < ActionDispatch::IntegrationTest
  setup do
    Octobox.config.stubs(:github_app).returns(false)
    @notifications_request = stub_notifications_request(body: '[]')
    @user = create(:user)
  end

  test 'authenticated users without access tokens are logged out' do
    sign_in_as(@user)
    @user.access_token = nil
    @user.save(validate: false) # Requires access token

    get '/settings'
    assert_redirected_to login_path
  end

  test 'GET #new renders login page' do
    get '/login'
    assert_template 'sessions/new'
  end

  test 'GET #new redirects to /root if already logged in' do
    sign_in_as(@user)
    get '/login'
    assert_redirected_to '/'
  end

  test 'POST #create finds the GitHub user from the hash and redirects to the root_path' do
    OmniAuth.config.mock_auth[:github].uid = @user.github_id
    post '/auth/github/callback'

    assert_redirected_to root_path
  end

  test 'POST #create creates a GitHub user from the hash and redirects to the root_path' do
    post '/auth/github/callback'

    assert User.find_by(github_id: OmniAuth.config.mock_auth[:github].uid)
    assert_redirected_to root_path
  end

  test 'POST #create persists GitHub App refresh credentials' do
    expires_at = 8.hours.from_now.to_i
    OmniAuth.config.mock_auth[:github_app] = OmniAuth::AuthHash.new(
      'provider' => 'github_app',
      'uid' => @user.github_id,
      'info' => {'nickname' => @user.github_login},
      'credentials' => {
        'token' => 'expiring-access-token',
        'refresh_token' => 'rotating-refresh-token',
        'expires_at' => expires_at,
        'expires' => true
      }
    )

    post '/auth/github_app/callback', env: {'omniauth.auth' => OmniAuth.config.mock_auth[:github_app]}

    assert_redirected_to root_path
    @user.reload
    assert_equal 'expiring-access-token', @user.app_token
    assert_equal 'rotating-refresh-token', @user.app_refresh_token
    assert_equal expires_at, @user.app_token_expires_at.to_i
  ensure
    OmniAuth.config.mock_auth.delete(:github_app)
  end

  %w[refresh_token expires_at].each do |missing_field|
    test "POST #create rejects expiring GitHub App credentials without #{missing_field}" do
      credentials = {
        'token' => 'expiring-access-token',
        'refresh_token' => 'rotating-refresh-token',
        'expires_at' => 8.hours.from_now.to_i,
        'expires' => true
      }
      credentials.delete(missing_field)
      auth = OmniAuth::AuthHash.new(
        'provider' => 'github_app',
        'uid' => @user.github_id,
        'info' => {'nickname' => @user.github_login},
        'credentials' => credentials
      )

      post '/auth/github_app/callback', env: {'omniauth.auth' => auth}

      assert_redirected_to root_path
      assert_equal 'There was a problem authenticating with GitHub, please try again.', flash[:error]
      assert_nil @user.reload.app_token
    end
  end

  {
    'without an access token' => {'expires' => false},
    'with partial refresh metadata' => {
      'token' => 'expiring-access-token',
      'refresh_token' => 'rotating-refresh-token',
      'expires' => false
    }
  }.each do |description, credentials|
    test "POST #create rejects GitHub App credentials #{description}" do
      auth = OmniAuth::AuthHash.new(
        'provider' => 'github_app',
        'uid' => @user.github_id,
        'info' => {'nickname' => @user.github_login},
        'credentials' => credentials
      )

      post '/auth/github_app/callback', env: {'omniauth.auth' => auth}

      assert_redirected_to root_path
      assert_equal 'There was a problem authenticating with GitHub, please try again.', flash[:error]
      assert_nil @user.reload.app_token
    end
  end

  test 'POST #create redirects to a relative omniauth origin' do
    OmniAuth.config.mock_auth[:github].uid = @user.github_id
    OmniAuth.config.before_callback_phase { |env| env['omniauth.origin'] = '/settings' }

    post '/auth/github/callback'
    assert_redirected_to '/settings'
  ensure
    OmniAuth.config.before_callback_phase = nil
  end

  test 'POST #create ignores an absolute omniauth origin' do
    OmniAuth.config.mock_auth[:github].uid = @user.github_id
    OmniAuth.config.before_callback_phase { |env| env['omniauth.origin'] = 'https://evil.com' }

    post '/auth/github/callback'
    assert_redirected_to root_path
  ensure
    OmniAuth.config.before_callback_phase = nil
  end

  test 'POST #create ignores a protocol-relative omniauth origin' do
    OmniAuth.config.mock_auth[:github].uid = @user.github_id
    OmniAuth.config.before_callback_phase { |env| env['omniauth.origin'] = '//evil.com' }

    post '/auth/github/callback'
    assert_redirected_to root_path
  ensure
    OmniAuth.config.before_callback_phase = nil
  end

  test 'POST #create forces the user to sync their notifications if they have synced before' do
    OmniAuth.config.mock_auth[:github].uid = @user.github_id

    post '/auth/github/callback'
    assert_sidekiq_job_enqueued(SyncNotificationsWorker, @user.id)
  end

  test 'POST #create redirects to the root_path with an error message if they are not an org member' do
    OmniAuth.config.mock_auth[:github].uid           = @user.github_id
    OmniAuth.config.mock_auth[:github].info.nickname = @user.github_login

    stub_restricted_access_enabled
    stub_env_var('GITHUB_ORGANIZATION_ID', 1)
    stub_organization_membership_request(organization_id: 1, user: @user.github_login, successful: false)

    post '/auth/github/callback'
    assert_redirected_to root_path
    assert_equal 'Access denied.', flash[:error]
  end

  test 'POST #create redirects to the root_path with an error message if they are not an team member' do
    OmniAuth.config.mock_auth[:github].uid           = @user.github_id
    OmniAuth.config.mock_auth[:github].info.nickname = @user.github_login

    stub_restricted_access_enabled
    stub_env_var('GITHUB_TEAM_ID', 1)
    stub_team_membership_request(team_id: 1, user: @user.github_login, successful: false)

    post '/auth/github/callback'
    assert_redirected_to root_path
    assert_equal 'Access denied.', flash[:error]
  end

  test 'POST #create is successful if the user is an org member' do
    OmniAuth.config.mock_auth[:github].uid           = @user.github_id
    OmniAuth.config.mock_auth[:github].info.nickname = @user.github_login

    stub_restricted_access_enabled
    stub_env_var('GITHUB_ORGANIZATION_ID', 1)
    stub_organization_membership_request(organization_id: 1, user: @user.github_login, successful: true)

    post '/auth/github/callback'
    assert_redirected_to root_path
    assert_nil flash[:error]
  end

  test 'POST #create is successful if the user is a team member' do
    OmniAuth.config.mock_auth[:github].uid           = @user.github_id
    OmniAuth.config.mock_auth[:github].info.nickname = @user.github_login

    stub_restricted_access_enabled
    stub_env_var('GITHUB_TEAM_ID', 1)
    stub_team_membership_request(team_id: 1, user: @user.github_login, successful: true)

    post '/auth/github/callback'
    assert_redirected_to root_path
    assert_nil flash[:error]
  end

  test 'GET #destroy redirects to /' do
    cookies['user_id'] = 1
    get '/logout'
    assert_redirected_to '/'
    assert_empty cookies['user_id']
  end

  test 'GET #failure redirects to / and sets a flash message' do
    get '/auth/failure'

    assert_redirected_to '/'
    assert_equal 'There was a problem authenticating with GitHub, please try again.', flash[:error]
  end
end
