# frozen_string_literal: true

require "test_helper"

class ResultsTest < Minitest::Test
  BODY = <<~JSON
    {"model": "decisionnode-1.0",
     "answers": {
       "route": {"type": "choice", "choice": "billing", "confidence": 0.8200000000000001,
                 "probabilities": {"billing": 0.8200000000000001, "bug": 0.12, "account": 0.060000000000000005}},
       "urgency": {"type": "score", "score": 2.31, "confidence": 0.5,
                   "probabilities": {"0": 0.1, "1": 0.2, "2": 0.3, "3": 0.4},
                   "legend": {"0": "routine", "1": "today", "2": "urgent", "3": {"what": "critical"}}},
       "escalate": {"type": "truth", "truth": 0.94},
       "future": {"type": "ranking", "order": ["b", "a"]}},
     "usage": {"input_tokens": 41, "output_tokens": 0}}
  JSON

  HEADERS = {
    "x-request-id" => "req_1",
    "x-decisionnode-latency-ms" => "23",
    "x-decisionnode-safety" => "harm=0.912;flagged, self_harm=0.004"
  }.freeze

  def decision
    DecisionNode::Decision.new(JSON.parse(BODY), HEADERS)
  end

  def test_answers_are_typed_and_read_by_id
    d = decision
    assert_instance_of DecisionNode::ChoiceAnswer, d["route"]
    assert_instance_of DecisionNode::ScoreAnswer, d[:urgency]
    assert_in_delta 0.94, d["escalate"].truth, 0
    assert_raises(KeyError) { d["missing"] }
  end

  def test_numbers_are_not_rounded
    route = decision["route"]
    assert_equal 0.8200000000000001, route.confidence
    assert_equal 0.060000000000000005, route.probabilities["account"]
  end

  def test_score_maps_have_integer_keys
    urgency = decision["urgency"]
    assert_equal [0, 1, 2, 3], urgency.probabilities.keys
    assert_equal({ "what" => "critical" }, urgency.legend[3])
  end

  def test_unknown_answer_type_keeps_raw_fields
    future = decision["future"]
    assert_instance_of DecisionNode::UnknownAnswer, future
    assert_kind_of DecisionNode::Answer, future
    assert_equal "ranking", future.type
    assert_equal %w[b a], future["order"]
  end

  def test_malformed_known_answers_are_unknown
    malformed = {
      "t_missing" => { "type" => "truth" },
      "t_string" => { "type" => "truth", "truth" => "0.9" },
      "t_bool" => { "type" => "truth", "truth" => true },
      "c_no_choice" => { "type" => "choice", "confidence" => 0.5, "probabilities" => { "a" => 1.0 } },
      "c_bad_probs" => { "type" => "choice", "choice" => "a", "confidence" => 0.5, "probabilities" => [1.0] },
      "c_bad_value" => { "type" => "choice", "choice" => "a", "confidence" => 0.5, "probabilities" => { "a" => "x" } },
      "s_no_legend" => { "type" => "score", "score" => 1.0, "confidence" => 0.5, "probabilities" => { "0" => 1.0 } },
      "s_bad_key" => { "type" => "score", "score" => 1.0, "confidence" => 0.5,
                       "probabilities" => { "low" => 1.0 }, "legend" => { "0" => "low" } },
      "s_bad_score" => { "type" => "score", "score" => nil, "confidence" => 0.5,
                         "probabilities" => { "0" => 1.0 }, "legend" => { "0" => "low" } },
      "not_an_object" => 0.5
    }
    d = DecisionNode::Decision.new({ "answers" => malformed }, {})
    malformed.each do |id, raw|
      assert_instance_of DecisionNode::UnknownAnswer, d[id], id
      assert_equal(raw.is_a?(Hash) ? raw : { "value" => raw }, d[id].raw, id)
    end
    assert_equal "truth", d["t_missing"].type
  end

  def test_metadata
    d = decision
    assert_equal "decisionnode-1.0", d.model
    assert_equal 41, d.usage.input_tokens
    assert_equal "req_1", d.request_id
    assert_equal 23, d.latency_ms
  end

  def test_usage_absent_is_nil
    d = DecisionNode::Decision.new({ "answers" => {} }, {})
    assert_nil d.usage.input_tokens
    assert_nil d.usage.output_tokens
  end

  def test_latency_absent_is_nil
    assert_nil DecisionNode::Decision.new(JSON.parse(BODY), {}).latency_ms
  end

  def test_safety_flagged
    s = decision.safety
    assert s.checked?
    assert_equal 0.912, s.harm
    assert_equal 0.004, s.self_harm
    assert_equal ["harm"], s.flagged
    assert_equal({ "checked" => true, "harm" => 0.912, "self_harm" => 0.004, "flagged" => ["harm"] }, s.to_h)
  end

  def test_safety_blocked_counts_as_flagged
    s = DecisionNode::Safety.parse("harm=0.99;blocked, self_harm=0.01")
    assert_equal ["harm"], s.flagged
  end

  def test_safety_unchecked
    s = DecisionNode::Safety.parse('unchecked;reason="timeout"')
    refute s.checked?
    assert_equal "timeout", s.reason
    assert_equal({ "checked" => false, "reason" => "timeout" }, s.to_h)
  end

  def test_no_safety_header
    assert_nil DecisionNode::Safety.parse(nil)
  end

  def test_model_limits
    m = DecisionNode::ModelInfo.new("name" => "decisionnode-1.0", "description" => "d", "release_date" => "2026-10-01",
                                    "max_input_tokens" => 32_768)
    assert_equal({ "max_input_tokens" => 32_768 }, m.limits)
  end

  STRICT = DecisionNode::TruthAnswer::STRICT_TYPE

  def test_the_strict_type_name_reads_as_truth
    answer = DecisionNode::Answer.from({ "type" => STRICT, STRICT => 0.07 })
    assert_instance_of DecisionNode::TruthAnswer, answer
    assert_in_delta 0.07, answer.truth
    assert_instance_of DecisionNode::UnknownAnswer, DecisionNode::Answer.from({ "type" => STRICT, "truth" => 0.07 })
  end

  def test_number_answer
    raw = { "type" => "number", "number" => 7, "expected" => 7.0, "confidence" => 0.78,
            "probabilities" => { "6" => 0.105, "7" => 0.783, "8" => 0.098 } }
    answer = DecisionNode::Answer.from(raw)
    assert_instance_of DecisionNode::NumberAnswer, answer
    assert_equal [7, 7.0, 0.78], [answer.number, answer.expected, answer.confidence]
    assert_kind_of Integer, answer.number
    assert_equal({ "6" => 0.105, "7" => 0.783, "8" => 0.098 }, answer.probabilities)
  end

  def test_a_malformed_number_answer_is_unknown
    raw = { "type" => "number", "number" => "7", "expected" => 7.0, "confidence" => 0.5, "probabilities" => {} }
    assert_instance_of DecisionNode::UnknownAnswer, DecisionNode::Answer.from(raw)
  end

  def test_model_info_sessions_and_batch
    m = DecisionNode::ModelInfo.new("name" => "decisionnode-1.0", "context_tokens" => 32_768,
                                    "sessions" => { "max_per_key" => 4 }, "batch" => { "add_bytes" => 10_485_760 })
    assert_equal 4, m.sessions["max_per_key"]
    assert_equal 4, m.limit(:sessions, :max_per_key)
    assert_equal 10_485_760, m.batch["add_bytes"]
    assert_equal 32_768, m.limit("context_tokens")
  end
end
