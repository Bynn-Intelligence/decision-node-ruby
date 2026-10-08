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

    # A value on a grid of numbers from `min` to `max` in steps of `step`.
    # An argument left out is left out of the wire form, so the server's
    # defaults apply: 0, 255 and 1.
    #
    #   number("How many cars are visible?", min: 0, max: 50)
    #   number("Rating?", min: 0, max: 5, step: 0.5)
    def number(instructions = nil, min: nil, max: nil, step: nil)
      question = { "type" => "number" }
      question["instructions"] = instructions unless instructions.nil?
      question["min"] = min unless min.nil?
      question["max"] = max unless max.nil?
      question["step"] = step unless step.nil?
      question
    end

    # One spot in an image, answered with its `x` and `y`. `image` is the id
    # of the image to look in, needed when the request has two or more;
    # `units` is "pixels" (the API's default) or "normalized". Each is left
    # out of the wire form when not given.
    #
    #   point("Point to the yellow package closest to the robot arm.")
    def point(instructions = nil, image: nil, units: nil)
      place("point", instructions, image, units)
    end

    # A rectangle in an image, answered with its top-left (`x1`, `y1`) and
    # bottom-right (`x2`, `y2`) corners. `image` and `units` as for #point.
    #
    #   box("Draw a box around the damaged package.", image: "belt")
    def box(instructions = nil, image: nil, units: nil)
      place("box", instructions, image, units)
    end

    def place(type, instructions, image, units)
      question = { "type" => type }
      question["instructions"] = instructions unless instructions.nil?
      question["image"] = image unless image.nil?
      question["units"] = units unless units.nil?
      question
    end
    private_class_method :place
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

    # See Questions.number.
    def number(instructions = nil, min: nil, max: nil, step: nil)
      Questions.number(instructions, min: min, max: max, step: step)
    end

    # See Questions.point.
    def point(instructions = nil, image: nil, units: nil)
      Questions.point(instructions, image: image, units: units)
    end

    # See Questions.box.
    def box(instructions = nil, image: nil, units: nil)
      Questions.box(instructions, image: image, units: units)
    end
  end
end
