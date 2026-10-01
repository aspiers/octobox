module ReactionSummary
  CONTENTS = %w[+1 -1 laugh hooray confused heart rocket eyes].freeze

  module_function

  def from(resource)
    attributes = resource.respond_to?(:to_h) ? resource.to_h : resource
    return unless attributes.respond_to?(:key?)

    summary = attributes['reactions'] || attributes[:reactions]
    return if summary.nil?

    summary = summary.to_h if summary.respond_to?(:to_h)
    return unless summary.respond_to?(:[])

    CONTENTS.each_with_object({}) do |content, counts|
      value = summary[content] || summary[content.to_sym]
      count = Integer(value, exception: false)
      counts[content] = count if count&.positive?
    end
  end

  def valid_counts(counts)
    source = counts.respond_to?(:to_h) ? counts.to_h : {}
    CONTENTS.each_with_object({}) do |content, normalized|
      count = Integer(source[content] || source[content.to_sym], exception: false)
      normalized[content] = count if count&.positive?
    end
  end
end
