# frozen_string_literal: true

class DecisionNode
  # Question builders. Each returns the question's wire form as a plain Hash,
  # so a builder and a Hash copied from the API documentation are interchangeable.
  #
  #   DecisionNode.truth("Escalate to a human now?")
  #
  # or, to call them without the prefix:
  #
  #   include DecisionNode::Questions
  #   truth("Escalate to a human now?")
  #
  # Instructions, descriptions and levels take a string or any JSON value.
  module Questions
    module_function

    # A yes-or-no question answered as a probability.
    # The criteria are left out when neither side is given.
    def truth(instructions = nil, if_true: nil, if_false: nil)
      question = { "type" => "truth" }
      question["instructions"] = instructions unless instructions.nil?
      criteria = {}
      criteria["true"] = if_true unless if_true.nil?
      criteria["false"] = if_false unless if_false.nil?
      question["criteria"] = criteria unless criteria.empty?
      question
    end

    # One option of a set. `options` is a Hash of name to description, or an
    # Array of names (each description nil). Names are sent exactly as given.
    def choice(instructions = nil, options = nil)
      criteria =
        case options
        when nil then {}
        when Array then options.each_with_object({}) { |name, h| h[name.to_s] = nil }
        when Hash then options.each_with_object({}) { |(name, desc), h| h[name.to_s] = desc }
        else raise ArgumentError, "options must be a Hash of name to description or an Array of names"
        end
      question = { "type" => "choice" }
      question["instructions"] = instructions unless instructions.nil?
      question["criteria"] = criteria
      question
    end

    # A place on an ordered scale. `levels` is listed from low to high.
    def score(instructions = nil, levels = nil)
      question = { "type" => "score" }
      question["instructions"] = instructions unless instructions.nil?
      question["criteria"] = levels.nil? ? [] : levels.to_a
      question
    end
  end

  class << self
    # See Questions.truth.
    def truth(instructions = nil, if_true: nil, if_false: nil)
      Questions.truth(instructions, if_true: if_true, if_false: if_false)
    end

    # See Questions.choice.
    def choice(instructions = nil, options = nil)
      Questions.choice(instructions, options)
    end

    # See Questions.score.
    def score(instructions = nil, levels = nil)
      Questions.score(instructions, levels)
    end
  end
end
