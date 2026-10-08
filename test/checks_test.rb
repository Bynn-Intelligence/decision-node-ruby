# frozen_string_literal: true

require_relative "test_helper"

# The API's fixed question rules, checked locally.
class ChecksTest < Minitest::Test
  def refused(klass, question)
    error = assert_raises(klass) { DecisionNode::Checks.questions!({ "q" => question }) }
    assert_instance_of klass, error
    assert_nil error.status
    assert_nil error.request_id
    error
  end

  def accepted(question)
    assert_nil DecisionNode::Checks.questions!({ "q" => question })
  end

  def test_choice_counts
    refused(DecisionNode::BadRequestError, DecisionNode.choice("?", []))
    refused(DecisionNode::BadRequestError, DecisionNode.choice("?", (1..256).map(&:to_s)))
    accepted(DecisionNode.choice("?", (1..255).map(&:to_s)))
  end

  def test_score_counts
    error = refused(DecisionNode::ValidationError, DecisionNode.score("?", []))
    assert_equal ["body", "questions", "q", "score", "criteria"], error.entries.first["loc"]
    assert_equal "too_short", error.entries.first["type"]
    refused(DecisionNode::BadRequestError, DecisionNode.score("?", (1..11).map(&:to_s)))
    accepted(DecisionNode.score("?", ["only"]))
    accepted({ "type" => "score", "criteria" => { "0" => "low", "1" => "high" } })
  end

  def test_truth_needs_instructions_or_criteria
    error = refused(DecisionNode::BadRequestError, DecisionNode.truth)
    assert_nil error.error_type # the API's plain-string 400
    assert_equal "Truth question must have criteria or instructions: q", error.message
    accepted(DecisionNode.truth(nil, if_true: "yes"))
    accepted(DecisionNode.truth(""))
  end

  def test_number_grids
    accepted(DecisionNode.number("n"))
    accepted(DecisionNode.number("n", min: 0, max: 4095))
    accepted(DecisionNode.number("n", min: 0, max: 409.5, step: 0.1))
    accepted(DecisionNode.number("n", min: 0.25, max: 2, step: 0.5))
    accepted(DecisionNode.number("n", min: 5, max: 5))
    assert_equal "too_long", refused(DecisionNode::ValidationError, DecisionNode.number("n", min: 0, max: 4096)).entries.first["type"]
    refused(DecisionNode::ValidationError, DecisionNode.number("n", min: 0, max: 1000, step: 0.1))
    refused(DecisionNode::ValidationError, DecisionNode.number("n", min: 60, max: 50))
    refused(DecisionNode::ValidationError, DecisionNode.number("n", step: 0))
    refused(DecisionNode::ValidationError, DecisionNode.number("n", step: -1))
    refused(DecisionNode::ValidationError, DecisionNode.number("n", max: Float::INFINITY))
    refused(DecisionNode::ValidationError, DecisionNode.number("n", min: true))
    refused(DecisionNode::BadRequestError, DecisionNode.number(nil, max: 10))
    refused(DecisionNode::BadRequestError, DecisionNode.number("", max: 10))
  end

  def test_unknown_and_malformed_questions
    error = refused(DecisionNode::BadRequestError, { "type" => "rank", "criteria" => [] })
    assert_equal ["Invalid request.", "api_usage_error"], [error.message, error.error_type]
    assert_equal "model_type", refused(DecisionNode::ValidationError, "not a hash").entries.first["type"]
    assert_equal "missing", refused(DecisionNode::ValidationError, { "instructions" => "?" }).entries.first["type"]
    error = refused(DecisionNode::ValidationError, DecisionNode.truth(42))
    assert_equal %w[string_type dict_type list_type], error.entries.map { |e| e["type"] }
  end

  def test_number_entries_match_the_server
    error = refused(DecisionNode::ValidationError, DecisionNode.number("n", min: 60, max: 50))
    assert_equal({ "type" => "less_than_equal", "loc" => %w[body questions q number min],
                   "msg" => "Input should be less than or equal to 50", "input" => 60, "ctx" => { "le" => 50 } },
                 error.entries.first)
    error = refused(DecisionNode::ValidationError, DecisionNode.number("n", min: 0.0000001))
    assert_equal "decimal_max_places", error.entries.first["type"]
    error = refused(DecisionNode::ValidationError, DecisionNode.number("n", min: 0, max: 1e14, step: 0.01))
    assert_equal({ "le" => 9_999_999_999_999.99 }, error.entries.first["ctx"])
    assert_equal "", error.message
  end

  def test_nesting_limit
    deep = 127.times.reduce("x") { |inner, _| [inner] } # 128 levels with the body's own object
    assert_nil DecisionNode::Checks.request!({ "state" => deep, "questions" => {} })
    error = assert_raises(DecisionNode::BadRequestError) do
      DecisionNode::Checks.request!({ "state" => [deep], "questions" => {} })
    end
    assert_equal ["Invalid request.", "api_usage_error"], [error.message, error.error_type]
  end
end
