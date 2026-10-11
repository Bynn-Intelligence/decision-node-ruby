# frozen_string_literal: true

require "test_helper"

# A decision whose boosters name ocr waits 30 s per attempt unless a timeout
# was set, and is never retried after a timeout: the server finishes that
# attempt and may bill it.
class OcrTimeoutTest < Minitest::Test
  include ClientHelpers

  Q = { "q" => DecisionNode.truth("?") }.freeze

  def ok
    FakeHTTP.json(200, truth_body)
  end

  def slow
    DecisionNode::TimeoutError.new("no complete response within 1 s")
  end

  def test_ocr_waits_30_seconds_when_no_timeout_was_set
    ["ocr", DecisionNode::Booster.new("ocr", options: { "prompt" => "the total" }), { "name" => "ocr" }, { name: "ocr" }].each do |b|
      http = FakeHTTP.new(ok)
      client(http).decide(questions: Q, boosters: ["age", b])
      assert_in_delta 30.0, http.calls.first.timeout
    end
  end

  def test_a_set_timeout_is_used_as_given
    http = FakeHTTP.new(ok)
    client(http, timeout: 5).decide(questions: Q, boosters: ["ocr"])
    assert_in_delta 5.0, http.calls.first.timeout
  end

  def test_other_decisions_keep_the_default
    http = FakeHTTP.new(FakeHTTP.json(200, truth_body(id: "check")))
    client(http).decide(questions: Q, boosters: ["age"])
    client(http).check(state: "s", instructions: "?")
    assert_equal [DecisionNode::DEFAULT_TIMEOUT] * 2, http.calls.map(&:timeout)
  end

  def test_never_retried_after_a_timeout
    http = FakeHTTP.new(slow, ok)
    assert_raises(DecisionNode::TimeoutError) { client(http, timeout: 1).decide(questions: Q, boosters: ["ocr"]) }
    assert_equal 1, http.calls.size
    # A helper too.
    http = FakeHTTP.new(slow, ok)
    assert_raises(DecisionNode::TimeoutError) do
      client(http, timeout: 1).check(state: "s", instructions: "?", boosters: [DecisionNode::Booster.new("ocr")])
    end
    assert_equal 1, http.calls.size
  end

  def test_other_retries_stay
    overloaded = FakeHTTP.json(529, { "detail" => { "error_type" => "overloaded_error", "message" => "busy" } })
    http = FakeHTTP.new(overloaded, DecisionNode::ConnectionError.new("reset"), ok)
    dn = client(http)
    dn.decide(questions: Q, boosters: ["ocr"])
    assert_equal 3, http.calls.size
  end

  def test_decide_many_applies_it_per_item
    first = true
    http = FakeHTTP.new(lambda do |call|
      if call.json["state"] == "with ocr"
        raise DecisionNode::TimeoutError, "slow"
      elsif first
        first = false
        raise DecisionNode::TimeoutError, "slow"
      end

      ok
    end)
    results = client(http, timeout: 1).decide_many([{ state: "with ocr", questions: Q, boosters: ["ocr"] },
                                                    { state: "without", questions: Q }], concurrency: 1)
    assert_instance_of DecisionNode::TimeoutError, results[0]
    assert_instance_of DecisionNode::Decision, results[1]
    assert_equal 1, http.calls.count { |c| c.json["state"] == "with ocr" }
    assert_equal 2, http.calls.count { |c| c.json["state"] == "without" }
  end
end
