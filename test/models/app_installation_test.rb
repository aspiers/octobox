# frozen_string_literal: true
require 'test_helper'

class AppInstallationTest < ActiveSupport::TestCase
  setup do
    @app_installation = create(:app_installation)
  end

  test 'must have a github id' do
    @app_installation.github_id = nil
    refute @app_installation.valid?
  end

  test 'must have a unique github_id' do
    app_installation = build(:app_installation, github_id: @app_installation.github_id)
    refute app_installation.valid?
  end

  test 'must have an account login' do
    @app_installation.account_login = nil
    refute @app_installation.valid?
  end

  test 'must have a account id' do
    @app_installation.account_id = nil
    refute @app_installation.valid?
  end

  test 'supports large GitHub account ids' do
    large_github_id = 2_147_483_648
    app_installation = create(
      :app_installation,
      app_id: large_github_id,
      account_id: large_github_id,
      target_id: large_github_id
    )

    assert_equal large_github_id, app_installation.app_id
    assert_equal large_github_id, app_installation.account_id
    assert_equal large_github_id, app_installation.target_id
  end

  test 'sync_repositories links accessible repositories and unlinks the rest' do
    linked = create(:repository, app_installation: @app_installation, full_name: 'andrew/kept')
    lost = create(:repository, app_installation: @app_installation, full_name: 'andrew/lost')
    remote = [
      { 'id' => linked.github_id, 'full_name' => 'andrew/kept', 'private' => false },
      { 'id' => 999_999_999, 'full_name' => 'andrew/new', 'private' => true }
    ]
    client = mock
    client.stubs(:list_app_installation_repositories).returns(stub(repositories: remote))
    @app_installation.stubs(:github_client).returns(client)

    @app_installation.sync_repositories

    assert_equal ['andrew/kept', 'andrew/new'], @app_installation.repositories.order(:full_name).pluck(:full_name)
    assert_nil lost.reload.app_installation_id
  end

  test 'sync_all syncs repositories for every installation' do
    remote_installation = {
      'id' => @app_installation.github_id,
      'app_id' => 1,
      'account' => { 'login' => 'andrew', 'id' => 1060, 'type' => 'User' },
      'target_type' => 'User',
      'target_id' => 1060,
      'permissions' => {}
    }
    remote_installation.define_singleton_method(:id) { self['id'] }
    Octobox.stubs(:github_app_client).returns(stub(find_app_installations: [remote_installation]))
    AppInstallation.any_instance.expects(:sync_repositories).once

    AppInstallation.sync_all
  end

  test 'map_from_api records the repository selection' do
    remote_installation = JSON.parse(File.read(Rails.root.join('test/fixtures/files/app_installation.json')))

    assert_equal 'selected', AppInstallation.map_from_api(remote_installation)[:repository_selection]
  end

  test 'all_repositories? is true only for installations covering every repository' do
    assert AppInstallation.new(repository_selection: 'all').all_repositories?
    refute AppInstallation.new(repository_selection: 'selected').all_repositories?
    refute AppInstallation.new.all_repositories?
  end
end
