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
    assert_equal ["body", "questions", "q"], error.entries.first["loc"]
    refused(DecisionNode::BadRequestError, DecisionNode.score("?", (1..11).map(&:to_s)))
    accepted(DecisionNode.score("?", ["only"]))
    accepted({ "type" => "score", "criteria" => { "0" => "low", "1" => "high" } })
  end

  def test_truth_needs_instructions_or_criteria
    error = refused(DecisionNode::BadRequestError, DecisionNode.truth)
    assert_equal "api_usage_error", error.error_type
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

  def test_unknown_types_are_left_to_the_server
    accepted({ "type" => "rank", "criteria" => [] })
    assert_nil DecisionNode::Checks.questions!({ "q" => "not a hash" })
  end
end
