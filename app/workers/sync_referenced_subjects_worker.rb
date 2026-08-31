# frozen_string_literal: true

class SyncReferencedSubjectsWorker
  include Sidekiq::Worker
  sidekiq_options queue: :sync_subjects, lock: :until_and_while_executing

  REPOSITORY_PATTERN = /[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+/
  FULL_REFERENCE_PATTERN = %r{(?<![A-Za-z0-9_.-])(#{REPOSITORY_PATTERN.source})#(\d+)}
  URL_REFERENCE_PATTERN = %r{https?://[^/]+/(#{REPOSITORY_PATTERN.source})/(?:issues|pull)/(\d+)}
  LOCAL_REFERENCE_PATTERN = /(?<![A-Za-z0-9_.\/-])#(\d+)/

  def perform(source_repository_full_name, texts)
    references(source_repository_full_name, texts).each do |repository_full_name, number|
      matching_subjects(repository_full_name, number).find_each do |subject|
        SyncReferenceActivitiesWorker.perform_async_if_configured(subject.id)
      end
    end
  end

  private

  def references(source_repository_full_name, texts)
    found = Set.new

    Array(texts).compact.each do |text|
      text.to_s.scan(URL_REFERENCE_PATTERN) { |repository, number| found << [repository, number.to_i] }
      text.to_s.scan(FULL_REFERENCE_PATTERN) { |repository, number| found << [repository, number.to_i] }
      text.to_s.scan(LOCAL_REFERENCE_PATTERN) { |number| found << [source_repository_full_name, number.first.to_i] }
    end

    found
  end

  def matching_subjects(repository_full_name, number)
    Subject.where("LOWER(repository_full_name) = ?", repository_full_name.to_s.downcase)
      .where("url LIKE ? OR url LIKE ?", "%/issues/#{number}", "%/pulls/#{number}")
  end
end
