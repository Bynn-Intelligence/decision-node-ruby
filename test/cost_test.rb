# frozen_string_literal: true

require "test_helper"

# usage.cost: what each answer cost, read as sent and never summed here.
class CostTest < Minitest::Test
  def decision(cost)
    usage = { "input_tokens" => 62, "output_tokens" => 0 }
    usage["cost"] = cost unless cost.nil?
    DecisionNode::Decision.new({ "model" => "decisionnode-moe-0.9.0-rc1", "answers" => {}, "usage" => usage }, {})
  end

  def test_a_plain_answer
    cost = decision({ "usd" => 0.000002604, "model_usd" => 0.000002604, "boosters_usd" => 0, "free_tier" => false })
           .usage.cost
    assert_instance_of DecisionNode::Cost, cost
    assert_equal [0.000002604, 0.000002604, 0, false], [cost.usd, cost.model_usd, cost.boosters_usd, cost.free_tier]
    assert_instance_of Integer, cost.boosters_usd
  end

  def test_usd_is_the_servers_figure_never_the_sum_of_the_parts
    cost = decision({ "usd" => 0.036014322, "model_usd" => 0.000014322, "boosters_usd" => 0.036,
                      "free_tier" => false }).usage.cost
    assert_equal 0.036014322, cost.usd
    refute_equal 0.000014322 + 0.036, cost.usd
  end

  def test_the_free_tier
    cost = decision({ "usd" => 0, "model_usd" => 0, "boosters_usd" => 0, "free_tier" => true }).usage.cost
    assert_equal [0, 0, 0, true], cost.to_a
  end

  def test_absent_is_nil_never_zeros
    assert_nil decision(nil).usage.cost
    assert_nil decision("free").usage.cost
    assert_nil DecisionNode::Decision.new({ "answers" => {} }, {}).usage.cost
  end

  def test_a_field_of_the_wrong_type_is_nil
    cost = decision({ "usd" => "0.1", "model_usd" => true, "boosters_usd" => nil, "free_tier" => "no" }).usage.cost
    assert_equal [nil, nil, nil, nil], cost.to_a
  end

  def test_a_batch_line
    line = { "custom_id" => "t1", "status" => 200, "headers" => {},
             "body" => { "model" => "decisionnode-moe-0.9.0-rc1", "answers" => {},
                         "usage" => { "input_tokens" => 10, "output_tokens" => 0,
                                      "cost" => { "usd" => 0.00000021, "model_usd" => 0.00000021,
                                                  "boosters_usd" => 0, "free_tier" => false } } } }
    result = DecisionNode::BatchResult.new(line, ->(*) { raise "not an error line" })
    assert_equal 0.00000021, result.decision.usage.cost.usd
  end

  def test_a_frame_reply_and_a_refused_frame
    usage = { "input_tokens" => 91, "output_tokens" => 0,
              "cost" => { "usd" => 0.000003185, "model_usd" => 0.000003185, "boosters_usd" => 0, "free_tier" => false } }
    reply = DecisionNode::Reply.new({ "seq" => 18, "answers" => {}, "usage" => usage })
    assert_equal [91, 0.000003185], [reply.usage.input_tokens, reply.usage.cost.usd]
    refused = DecisionNode::FrameError.new({ "seq" => 19, "error" => { "error_type" => "refusal_error" },
                                             "usage" => { "input_tokens" => 0, "output_tokens" => 0,
                                                          "cost" => { "usd" => 0, "model_usd" => 0,
                                                                      "boosters_usd" => 0, "free_tier" => false } } })
    assert_equal 0, refused.usage.cost.usd
    assert_nil DecisionNode::Reply.new({ "seq" => 20, "usage" => { "input_tokens" => 5 } }).usage.cost
  end

  def test_usage_new_keeps_its_positional_form
    usage = DecisionNode::Usage.new(1, 0)
    assert_equal [1, 0, nil], [usage.input_tokens, usage.output_tokens, usage.cost]
  end
end
