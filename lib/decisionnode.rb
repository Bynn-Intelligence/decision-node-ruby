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
require_relative "decisionnode/image_header"
require_relative "decisionnode/image"
require_relative "decisionnode/video"
require_relative "decisionnode/boosters"
require_relative "decisionnode/checks"
require_relative "decisionnode/results"
require_relative "decisionnode/transport"
require_relative "decisionnode/uploads"
require_relative "decisionnode/session"
require_relative "decisionnode/supervisor"
require_relative "decisionnode/batches"
require_relative "decisionnode/collections"
require_relative "decisionnode/keys"
require_relative "decisionnode/client"

class DecisionNode
  # Loaded with the WebSocket library on the first session.
  autoload :SessionStream, File.expand_path("decisionnode/session_stream", __dir__)
end
