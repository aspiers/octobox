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

  def initialize(client)
    @client = client
  end

  def resource(url)
    @client.get(url, request_options)
  rescue Octokit::ClientError, Octokit::InternalServerError
    nil
  end

  def collection(url, params: {})
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
  rescue Octokit::ClientError, Octokit::InternalServerError, Faraday::Error
    Result.new(items: items, complete: false)
  end

  private

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
