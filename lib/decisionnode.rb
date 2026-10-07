# frozen_string_literal: true

# DecisionNode is both the client and the namespace of this gem:
#
#   require "decisionnode"
#
#   dn = DecisionNode.new # reads DECISIONNODE_API_KEY
#   d = dn.decide(state: "...", questions: { "escalate" => DecisionNode.truth("Escalate?") })
#   d["escalate"].truth
class DecisionNode
  # One result of #decide_many: a Decision, or the error that request ended
  # with. Both include this module, so `result.is_a?(DecisionNode::DecisionResult)`
  # holds for each, and `result.is_a?(DecisionNode::Decision)` tells them apart.
  module DecisionResult; end
end

require_relative "decisionnode/version"
require_relative "decisionnode/errors"
require_relative "decisionnode/questions"
require_relative "decisionnode/image"
require_relative "decisionnode/results"
require_relative "decisionnode/transport"
require_relative "decisionnode/client"
