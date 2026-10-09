# frozen_string_literal: true

require "test_helper"

# The fallback option on the request, and Decision#fallback from the
# fallback headers of the response.
class FallbackTest < Minitest::Test
  include ClientHelpers

  Q = { "q" => DecisionNode.truth("?") }.freeze

  def ok(headers = {})
    FakeHTTP.json(200, truth_body, headers)
  end

  def answer_for(question)
    case question["type"]
    when "truth" then { "type" => "truth", "truth" => 0.5 }
    when "choice" then { "type" => "choice", "choice" => "a", "confidence" => 0.5, "probabilities" => { "a" => 0.5 } }
    when "score" then { "type" => "score", "score" => 1, "confidence" => 0.5, "probabilities" => { "0" => 0.5 }, "legend" => { "0" => "lo" } }
    when "number" then { "type" => "number", "number" => 1, "expected" => 1, "confidence" => 0.5, "probabilities" => { "1" => 0.5 } }
    end
  end

  # ---- the request

  def test_fallback_is_sent_only_when_given
    [true, false].each do |value|
      http = FakeHTTP.new(ok)
      client(http).decide(state: "s", questions: Q, model: "decisionnode-1.0", fallback: value)
      assert_equal value, http.calls.first.json["fallback"]
      assert_equal %w[model state questions fallback], http.calls.first.json.keys
    end

    http = FakeHTTP.new(ok)
    client(http).decide(state: "s", questions: Q)
    refute http.calls.first.json.key?("fallback")
    assert_equal JSON.generate({ "model" => "decisionnode-latest", "state" => "s", "questions" => Q }), http.calls.first.body
  end

  def test_fallback_follows_the_boosters
    http = FakeHTTP.new(ok)
    client(http).decide(state: "s", questions: Q, boosters: ["age"], fallback: false)
    assert_equal %w[model state questions boosters fallback], http.calls.first.json.keys
  end

  def test_every_helper_takes_fallback
    http = FakeHTTP.new(lambda { |call|
      ids = call.json["questions"].keys
      FakeHTTP.json(200, { "model" => "m", "answers" => ids.to_h { |id| [id, answer_for(call.json["questions"][id])] } })
    })
    dn = client(http)
    dn.check(state: "s", instructions: "?", fallback: false)
    dn.classify(state: "s", instructions: "?", options: %w[a b], fallback: false)
    dn.score(state: "s", instructions: "?", levels: %w[lo hi], fallback: false)
    dn.number(state: "s", instructions: "?", fallback: false)
    dn.gate(action: "a", fallback: false)
    assert_equal 5, http.calls.size
    http.calls.each { |c| assert_equal false, c.json["fallback"] }
  end

  def test_decide_many_and_batch_lines_take_fallback
    http = FakeHTTP.new(ok)
    client(http).decide_many([{ questions: Q, fallback: false }, { questions: Q }])
    sent = http.calls.map(&:json).sort_by { |b| b.key?("fallback") ? 0 : 1 }
    assert_equal false, sent[0]["fallback"]
    refute sent[1].key?("fallback")

    http = FakeHTTP.new(FakeHTTP.json(201, { "id" => "batch_01J9ZB8Q3T", "state" => "draft" }))
    client(http).batches.create([{ custom_id: "a", questions: Q, boosters: ["age"], fallback: false, extra: 1 },
                                 { custom_id: "b", questions: Q, fallback: nil }])
    lines = http.calls.first.body.split("\n").map { |l| JSON.parse(l) }
    assert_equal %w[custom_id model state questions boosters fallback extra], lines[0].keys
    assert_equal false, lines[0]["fallback"]
    refute lines[1].key?("fallback")
  end

  def test_check_request_takes_fallback
    dn = client(FakeHTTP.new(ok))
    assert_nil dn.check_request("decide", questions: Q, fallback: false)
    assert_nil dn.check_request("batches.create", requests: [{ custom_id: "a", questions: Q, fallback: true }])
  end

  def test_a_fallback_that_is_not_a_boolean_is_an_argument_error
    ["false", 0, :no].each do |value|
      http = FakeHTTP.new(ok)
      dn = client(http)
      assert_raises(ArgumentError) { dn.decide(questions: Q, fallback: value) }
      assert_raises(ArgumentError) { dn.check(instructions: "?", fallback: value) }
      assert_raises(ArgumentError) { dn.decide_many([{ questions: Q }, { questions: Q, fallback: value }]) }
      assert_raises(ArgumentError) { dn.batches.create([{ custom_id: "a", questions: Q, fallback: value }]) }
      assert_raises(ArgumentError) { dn.check_request("decide", questions: Q, fallback: value) }
      assert_empty http.calls, value.inspect
    end
  end

  def test_sessions_take_no_fallback
    dn = client(FakeHTTP.new(ok))
    assert_raises(ArgumentError) { dn.open_session(questions: Q, fallback: false) }
  end

  # ---- the response

  def test_a_fallback_answer
    http = FakeHTTP.new(FakeHTTP.json(200, truth_body.merge("model" => "decisionnode-1.0-flash"),
                                      "x-decisionnode-fallback" => "decisionnode-1.0-flash",
                                      "x-decisionnode-requested-model" => "decisionnode-1.0"))
    d = client(http).decide(questions: Q, model: "decisionnode-1.0")
    assert_equal "decisionnode-1.0-flash", d.model
    assert_equal DecisionNode::Fallback.new("decisionnode-1.0-flash", "decisionnode-1.0"), d.fallback
    assert_equal ["decisionnode-1.0-flash", "decisionnode-1.0"], [d.fallback.served_model, d.fallback.requested_model]
  end

  def test_an_ordinary_answer_has_no_fallback
    d = client(FakeHTTP.new(ok)).decide(questions: Q)
    assert_nil d.fallback

    d = client(FakeHTTP.new(ok("x-decisionnode-fallback" => "decisionnode-1.0-flash"))).decide(questions: Q)
    assert_equal DecisionNode::Fallback.new("decisionnode-1.0-flash", nil), d.fallback
  end

  def test_batch_results_read_the_fallback_headers
    line = { "custom_id" => "a", "status" => 200, "body" => truth_body,
             "headers" => { "X-DecisionNode-Fallback" => "decisionnode-1.0-flash", "x-decisionnode-requested-model" => "decisionnode-1.0" } }
    plain = { "custom_id" => "b", "status" => 200, "body" => truth_body, "headers" => {} }
    text = [line, plain].map { |l| JSON.generate(l) }.join("\n")
    http = FakeHTTP.new(DecisionNode::HTTPResponse.new(200, { "content-type" => "application/x-ndjson" }, "#{text}\n"))
    first, second = client(http).batches.results("batch_01J9ZB8Q3T").to_a
    assert_equal DecisionNode::Fallback.new("decisionnode-1.0-flash", "decisionnode-1.0"), first.decision.fallback
    assert_nil second.decision.fallback
  end
end
