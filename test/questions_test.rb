# frozen_string_literal: true

require "test_helper"

class QuestionsTest < Minitest::Test
  def test_truth_without_criteria
    assert_equal({ "type" => "truth", "instructions" => "Escalate?" }, DecisionNode.truth("Escalate?"))
  end

  def test_truth_with_one_side
    q = DecisionNode.truth("Refund?", if_true: "asks for money back")
    assert_equal({ "true" => "asks for money back" }, q["criteria"])
  end

  def test_truth_with_both_sides_keeps_order
    q = DecisionNode.truth("Refund?", if_true: "yes", if_false: "no")
    assert_equal %w[true false], q["criteria"].keys
  end

  def test_truth_criteria_only
    q = DecisionNode.truth(if_true: "a", if_false: "b")
    refute q.key?("instructions")
  end

  def test_choice_from_hash_keeps_names_and_order
    q = DecisionNode.choice("Where?", { "billing" => "money", "" => "empty", bug: "broken" })
    assert_equal ["billing", "", "bug"], q["criteria"].keys
    assert_equal "money", q["criteria"]["billing"]
  end

  def test_choice_from_list_of_names
    q = DecisionNode.choice("Where?", %w[billing bug])
    assert_equal({ "billing" => nil, "bug" => nil }, q["criteria"])
  end

  def test_choice_rejects_other_option_types
    assert_raises(ArgumentError) { DecisionNode.choice("Where?", "billing") }
  end

  def test_score_levels_low_to_high
    q = DecisionNode.score("How urgent?", [{ "what" => "routine" }, "urgent"])
    assert_equal({ "type" => "score", "instructions" => "How urgent?",
                   "criteria" => [{ "what" => "routine" }, "urgent"] }, q)
  end

  def test_questions_module_can_be_included
    obj = Object.new.extend(DecisionNode::Questions)
    assert_equal "truth", obj.send(:truth, "x")["type"]
  end

  def test_number_leaves_out_what_is_not_given
    assert_equal({ "type" => "number", "instructions" => "How many?" }, DecisionNode.number("How many?"))
    assert_equal({ "type" => "number", "instructions" => "T?", "min" => -40.5, "max" => 10.25, "step" => 0.25 },
                 DecisionNode::Questions.number("T?", min: -40.5, max: 10.25, step: 0.25))
  end

  def test_number_through_the_module
    obj = Object.new.extend(DecisionNode::Questions)
    assert_equal({ "type" => "number", "instructions" => "n", "max" => 9 }, obj.send(:number, "n", max: 9))
  end
end
