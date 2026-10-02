# frozen_string_literal: true

require 'application_system_test_case'

class PreviewCommentInsertionSystemTest < ApplicationSystemTestCase
  setup do
    Octobox.config.stubs(:include_comments).returns(true)
    user = create(:user)
    repository = create(:repository, full_name: 'octobox/octobox', private: false)
    subject = create(:subject, repository: repository)
    create(:notification, user: user, subject_url: subject.url,
           repository_full_name: repository.full_name, subject_type: 'Issue')
    sign_in_as(user)
  end

  test 'reply insertion prefers the conversation wrapper and is deduplicated after refresh' do
    install_reply(wrapper: true)
    receive_reply
    assert_selector '.notification-conversation #comment-123', count: 1
    assert_equal '', find('#comment_body').value

    page.execute_script <<~JS
      document.querySelector('.notification-conversation').outerHTML = '<div class="notification-conversation"><div data-event-identity="merge">Merged</div><div id="comment-123">Posted reply</div></div>';
    JS
    assert_selector '#comment-123', count: 1
    assert_equal ['merge', 'comment-123'], page.evaluate_script("Array.from(document.querySelector('.notification-conversation').children).map(function(node) { return node.dataset.eventIdentity || node.id; })")
  end

  test 'reply insertion still supports standalone previews without a wrapper' do
    install_reply(wrapper: false)
    receive_reply
    receive_reply
    assert_selector '.discussion-thread #comment-123', count: 1
    assert_equal '', find('#comment_body').value
  end

  test 'reply insertion rejects unexpected response elements' do
    install_reply(wrapper: true)
    page.execute_script "$('#reply').trigger('ajax:success', ['<div id=unexpected>Unexpected reply</div>'])"
    assert_no_selector '#unexpected'
    assert_equal 'Draft reply', find('#comment_body').value
  end

  private

  def install_reply(wrapper:)
    conversation = wrapper ? '<div class="notification-conversation"></div>' : ''
    page.execute_script <<~JS
      document.querySelector('.flex-main').classList.add('show-thread');
      document.getElementById('thread').classList.remove('d-none');
      document.getElementById('thread').innerHTML = '<div class="discussion-thread">' + #{conversation.to_json} + '</div><form id="reply"><textarea id="comment_body"></textarea></form>';
      document.getElementById('comment_body').value = 'Draft reply';
    JS
  end

  def receive_reply
    page.execute_script "$('#reply').trigger('ajax:success', ['<div id=comment-123>Posted reply</div>'])"
  end
end
