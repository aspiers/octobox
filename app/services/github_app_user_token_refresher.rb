# frozen_string_literal: true

class GithubAppUserTokenRefresher
  Credentials = Struct.new(:access_token, :refresh_token, :expires_at, keyword_init: true)
  InvalidResponse = Class.new(StandardError)

  def initialize(refresh_token:, client: nil)
    @refresh_token = refresh_token
    @client = client || oauth_client
  end

  def refresh
    refreshed = @client.get_token(
      grant_type: 'refresh_token',
      refresh_token: @refresh_token
    ) do |request|
      request.headers['Accept'] = 'application/json'
    end
    validate!(refreshed)

    Credentials.new(
      access_token: refreshed.token,
      refresh_token: refreshed.refresh_token,
      expires_at: Time.zone.at(refreshed.expires_at)
    )
  end

  private

  def validate!(token)
    missing = []
    missing << 'access_token' if token.token.blank?
    missing << 'refresh_token' if token.refresh_token.blank?
    missing << 'expiry' unless token.expires_at
    return if missing.empty?

    raise InvalidResponse, "GitHub refresh response missing #{missing.join(', ')}"
  end

  def oauth_client
    OAuth2::Client.new(
      Octobox.config.github_app_client_id,
      Octobox.config.github_app_client_secret,
      site: Octobox.config.github_domain,
      token_url: "#{Octobox.config.github_domain}/login/oauth/access_token",
      auth_scheme: :request_body
    )
  end
end
