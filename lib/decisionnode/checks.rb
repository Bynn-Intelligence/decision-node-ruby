# frozen_string_literal: true

class DecisionNode
  # The API's fixed request rules, checked before any request so a request
  # the API would refuse never costs a round trip. A fault raises the class
  # the API would answer with (BadRequestError, or ValidationError where the
  # API answers 422), with no status and no request id. Limits counted in
  # tokens stay the server's to judge.
  module Checks
    MAX_IMAGES = 4
    MAX_CHOICE_OPTIONS = 255
    MAX_SCORE_LEVELS = 10
    MAX_GRID_VALUES = 4_096
    GRID_DEFAULTS = { "min" => 0, "max" => 255, "step" => 1 }.freeze

    module_function

    # Checks every question of a question map whose keys are Strings.
    def questions!(questions)
      questions.each do |id, q|
        next unless q.is_a?(Hash)

        case q["type"]
        when "choice" then choice!(id, q["criteria"])
        when "score" then score!(id, q["criteria"])
        when "truth", TruthAnswer::STRICT_TYPE then truth!(id, q)
        when "number" then number!(id, q)
        end
      end
      nil
    end

    # Checks the image list of one request: the count, unique ids and each
    # image's own rules.
    def images!(images)
      return nil if images.nil? || images.empty?

      bad_request("Too many images. Must have at most #{MAX_IMAGES} images.") if images.size > MAX_IMAGES
      ids = images.map { |img| img.is_a?(Image) ? img.id : (img["id"] || img[:id]).to_s }
      if (dup = ids.detect { |id| ids.count(id) > 1 })
        bad_request("Image ids must be unique: #{dup} is given more than once.")
      end
      images.each { |img| img.validate! if img.is_a?(Image) }
      nil
    end

    def choice!(id, criteria)
      return unless criteria.is_a?(Hash)

      bad_request("Choice question must have at least one choice: #{id}") if criteria.empty?
      return unless criteria.size > MAX_CHOICE_OPTIONS

      bad_request("Too many choices. Must have at most #{MAX_CHOICE_OPTIONS} choices.")
    end

    def score!(id, criteria)
      return unless criteria.is_a?(Array) || criteria.is_a?(Hash)

      if criteria.empty?
        invalid(id, "too_short", "a score needs at least one level", "question #{id}: a score needs at least one level")
      end
      return unless criteria.size > MAX_SCORE_LEVELS

      bad_request("Too many score levels. Must have at most #{MAX_SCORE_LEVELS} levels.")
    end

    def truth!(id, question)
      criteria = question["criteria"].is_a?(Hash) ? question["criteria"] : {}
      return unless question["instructions"].nil? && criteria["true"].nil? && criteria["false"].nil?

      bad_request("Truth question must have criteria or instructions: #{id}")
    end

    def number!(id, question)
      lo, hi, step = %w[min max step].map do |name|
        value = question[name]
        value.nil? ? Rational(GRID_DEFAULTS[name]) : exact(value)
      end
      %w[min max step].zip([lo, hi, step]).each do |name, value|
        invalid(id, "float_type", "#{name}: Input should be a valid number", "question #{id}: #{name} must be a number") if value.nil?
      end
      invalid(id, "greater_than", "step: Input should be greater than 0", "question #{id}: step must be above 0") unless step.positive?
      if lo > hi
        invalid(id, "less_than_equal", "min: Input should be at most max", "question #{id}: min is above max")
      end
      size = ((hi - lo) / step).floor + 1
      if size > MAX_GRID_VALUES
        invalid(id, "too_long", "the grid holds #{size} values, the limit is #{MAX_GRID_VALUES}",
                "question #{id}: the grid holds #{size} values, the limit is #{MAX_GRID_VALUES}")
      end
      instructions = question["instructions"]
      return unless instructions.nil? || instructions == ""

      bad_request("Number question must have instructions: #{id}")
    end

    # The exact value of a JSON number as written, or nil for any other value.
    def exact(value)
      case value
      when Integer then Rational(value)
      when Float then value.finite? ? Rational(value.to_s) : nil
      when Rational then value
      end
    end

    def bad_request(message)
      raise BadRequestError.new(message, error_type: "api_usage_error")
    end

    def invalid(id, type, msg, message)
      entry = { "type" => type, "loc" => ["body", "questions", id.to_s], "msg" => msg }
      raise ValidationError.new(message, entries: [entry])
    end
  end
end
