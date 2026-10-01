# frozen_string_literal: true
require 'test_helper'

class ReactionSummaryTest < ActiveSupport::TestCase
  test 'normalizes supported positive counts without identities or metadata' do
    remote = {
      'reactions' => {
        'total_count' => 8,
        'url' => 'https://api.github.com/reactions',
        '+1' => 4,
        '-1' => 0,
        'heart' => '3',
        'eyes' => 1,
        '<script>' => 99
      }
    }

    assert_equal({'+1' => 4, 'heart' => 3, 'eyes' => 1}, ReactionSummary.from(remote))
  end

  test 'distinguishes an absent summary from an authoritative empty summary' do
    assert_nil ReactionSummary.from('id' => 1)
    assert_equal({}, ReactionSummary.from('reactions' => {'total_count' => 0}))
  end
end
