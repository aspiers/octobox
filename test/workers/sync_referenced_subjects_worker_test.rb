# frozen_string_literal: true

require "test_helper"

class SyncReferencedSubjectsWorkerTest < ActiveSupport::TestCase
  test "refreshes local, qualified, and native URL references without duplicates" do
    local = create(
      :subject,
      repository_full_name: "example/source",
      url: "https://api.github.com/repos/example/source/issues/41"
    )
    qualified = create(
      :subject,
      repository_full_name: "example/target",
      url: "https://api.github.com/repos/example/target/pulls/99"
    )
    native_url = create(
      :subject,
      repository_full_name: "another/repo",
      url: "https://api.github.com/repos/another/repo/issues/7"
    )
    SyncReferenceActivitiesWorker.expects(:perform_async_if_configured).with(local.id).once
    SyncReferenceActivitiesWorker.expects(:perform_async_if_configured).with(qualified.id).once
    SyncReferenceActivitiesWorker.expects(:perform_async_if_configured).with(native_url.id).once

    SyncReferencedSubjectsWorker.new.perform(
      "example/source",
      [
        "Refs #41 and example/target#99",
        "See https://github.com/another/repo/issues/7 and example/target#99 again"
      ]
    )
  end

  test "does not refresh unreferenced subjects" do
    subject = create(:subject, repository_full_name: "example/source")
    SyncReferenceActivitiesWorker.expects(:perform_async_if_configured).never

    SyncReferencedSubjectsWorker.new.perform("example/source", ["No issue references here"])

    assert subject.persisted?
  end
end
