# frozen_string_literal: true
require 'test_helper'

class ReactionChipsHelperTest < ActionView::TestCase
  include NotificationsHelper

  test 'renders compact accessible chips in GitHub reaction order' do
    subject = build(:subject, reactions: {'eyes' => 1, '+1' => 2, 'heart' => 3})

    html = reaction_chips(subject)
    fragment = Nokogiri::HTML.fragment(html)
    chips = fragment.css('.reaction-chip')

    assert_equal 3, chips.length
    assert_equal ['thumbs up: 2 reactions', 'heart: 3 reactions', 'eyes: 1 reaction'], chips.map { |chip| chip['aria-label'] }
    assert_equal ['2', '3', '1'], chips.map { |chip| chip.at_css('.reaction-count').text }
  end

  test 'does not render unsupported reaction content as HTML' do
    subject = build(:subject, reactions: {'<script>alert(1)</script>' => 5, '+1' => 1})

    html = reaction_chips(subject)

    refute_includes html, '<script>'
    assert_includes html, 'thumbs up: 1 reaction'
  end
end
