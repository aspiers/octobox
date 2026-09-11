class GithubPreviewFetcher
  ACCEPT = 'application/vnd.github+json'.freeze
  API_VERSION = '2022-11-28'.freeze
  PAGE_SIZE = 100
  MAX_PAGES = 10

  class Result
    attr_reader :items

    def initialize(items:, complete:)
      @items = items
      @complete = complete
    end

    def complete?
      @complete
    end
  end

  RATE_LIMIT_HEADERS = %w[x-ratelimit-limit x-ratelimit-remaining x-ratelimit-reset retry-after].freeze

  def self.log_failure(error, operation:, subject_url:, logger: Rails.logger)
    headers = error.respond_to?(:response_headers) ? error.response_headers : {}
    normalized_headers = headers.to_h.transform_keys { |key| key.to_s.downcase.tr('_', '-') }
    event = {
      event: 'github_preview_fetch_failed',
      operation: operation,
      subject_url: subject_url,
      exception: error.class.name,
      rate_limit: normalized_headers.slice(*RATE_LIMIT_HEADERS)
    }
    event[:status] = error.response_status if error.respond_to?(:response_status)
    logger.warn(event.to_json)
  end

  def initialize(client, logger: Rails.logger)
    @client = client
    @logger = logger
  end

  def resource(url)
    @client.get(url, request_options)
  rescue Octokit::ClientError, Octokit::ServerError, Faraday::Error => error
    log_failure(error, operation: 'resource', subject_url: url)
    nil
  end

  def collection(url, operation: 'collection', subject_url: url, params: {})
    items = []
    next_url = url
    pages = 0

    while next_url && pages < MAX_PAGES
      options = request_options.merge(per_page: PAGE_SIZE)
      # GitHub's next links already carry the first request's cursor parameters.
      options.merge!(params) if pages.zero?
      page = @client.get(next_url, options)
      items.concat(Array(page))
      pages += 1
      next_url = next_page_url
    end

    Result.new(items: items, complete: next_url.nil?)
  rescue Octokit::ClientError, Octokit::ServerError, Faraday::Error => error
    log_failure(error, operation: operation, subject_url: subject_url)
    Result.new(items: items, complete: false)
  end

  private

  def log_failure(error, operation:, subject_url:)
    self.class.log_failure(error, operation: operation, subject_url: subject_url, logger: @logger)
  end

  def request_options
    {
      accept: ACCEPT,
      headers: {'X-GitHub-Api-Version' => API_VERSION}
    }
  end

  def next_page_url
    relation = @client.last_response&.rels&.[](:next)
    relation&.href&.to_s
  end
end
