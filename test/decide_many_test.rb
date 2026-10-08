# frozen_string_literal: true

require "test_helper"

class DecideManyTest < Minitest::Test
  include ClientHelpers

  def requests(count)
    Array.new(count) { |i| { state: "item #{i}", questions: { "q" => DecisionNode.truth("?") } } }
  end

  def test_results_in_input_order_with_failures_in_place
    http = FakeHTTP.new(lambda do |call|
      state = call.json["state"]
      sleep(rand * 0.02)
      if state == "item 1"
        FakeHTTP.json(422, { "detail" => [{ "msg" => "bad" }] })
      else
        FakeHTTP.json(200, truth_body(state.split.last.to_f / 10))
      end
    end)
    results = client(http).decide_many(requests(5), concurrency: 3)
    assert_equal 5, results.size
    assert_instance_of DecisionNode::ValidationError, results[1]
    [0, 2, 3, 4].each { |i| assert_in_delta i / 10.0, results[i]["q"].truth }
  end

  def test_concurrency_limit
    in_flight = 0
    peak = 0
    lock = Mutex.new
    http = FakeHTTP.new(lambda do |_call|
      lock.synchronize { peak = [peak, in_flight += 1].max }
      sleep 0.03
      lock.synchronize { in_flight -= 1 }
      FakeHTTP.json(200, truth_body)
    end)
    client(http).decide_many(requests(8), concurrency: 2)
    assert_equal 2, peak
  end

  def test_concurrency_below_one_is_an_argument_error
    [0, -1].each do |concurrency|
      http = FakeHTTP.new(FakeHTTP.json(200, truth_body))
      assert_raises(ArgumentError) { client(http).decide_many(requests(2), concurrency: concurrency) }
      assert_empty http.calls
    end
  end

  def test_an_invalid_request_is_an_argument_error_before_anything_is_sent
    gif = "GIF89a\x01\x00\x01\x00".b
    invalid = [
      { state: "c", questions: {} },
      { state: "c" },
      { state: "c", questions: { "q" => "not a question" } },
      { state: "c", questions: { "q" => DecisionNode.truth("?") }, images: "img" },
      { state: "c", questions: { "q" => DecisionNode.truth("?") }, images: [42] },
      { state: "c", questions: { "q" => DecisionNode.truth("?") }, colour: "red" },
      { state: "\xFF".b, questions: { "q" => DecisionNode.truth("?") } },
      "not a hash"
    ]
    invalid.each do |bad|
      http = FakeHTTP.new(FakeHTTP.json(200, truth_body))
      assert_raises(ArgumentError, bad.inspect) { client(http).decide_many(requests(2) + [bad], concurrency: 1) }
      assert_empty http.calls, bad.inspect
    end
    # Bytes in an unknown format are a request the API would refuse: a
    # BadRequestError for the whole call, and nothing is sent.
    http = FakeHTTP.new(FakeHTTP.json(200, truth_body))
    bad = { state: "c", questions: { "q" => DecisionNode.truth("?") }, images: [DecisionNode::Image.new("img", data: gif)] }
    assert_raises(DecisionNode::BadRequestError) { client(http).decide_many(requests(2) + [bad], concurrency: 1) }
    assert_empty http.calls
  end

  def test_unexpected_errors_become_decision_results
    http = FakeHTTP.new(->(_call) { raise KeyError, "boom" })
    results = client(http, max_retries: 0).decide_many(requests(2), concurrency: 1)
    results.each do |r|
      assert_instance_of DecisionNode::DecisionNodeError, r
      assert_instance_of KeyError, r.cause
    end
  end

  def test_results_are_decision_results
    http = FakeHTTP.new(FakeHTTP.json(200, truth_body), FakeHTTP.json(404, { "detail" => "x" }))
    results = client(http, max_retries: 0).decide_many(requests(2), concurrency: 1)
    assert(results.all?(DecisionNode::DecisionResult))
  end

  def test_string_keys_and_empty_list
    http = FakeHTTP.new(FakeHTTP.json(200, truth_body))
    dn = client(http)
    assert_empty dn.decide_many([])
    result = dn.decide_many([{ "state" => "s", "questions" => { "q" => DecisionNode.truth("?") } }])
    assert_instance_of DecisionNode::Decision, result.first
  end
end
