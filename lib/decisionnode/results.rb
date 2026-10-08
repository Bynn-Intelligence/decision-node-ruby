# frozen_string_literal: true

class DecisionNode
  # The base of every answer. `raw` holds every field the server sent.
  class Answer
    attr_reader :raw, :type

    # The typed answer for a known type whose fields are all present and of
    # the right type; an UnknownAnswer holding the raw fields otherwise, so a
    # new or malformed answer never fails the decision.
    def self.from(raw)
      return UnknownAnswer.new({ "value" => raw }) unless raw.is_a?(Hash)

      klass = TYPES[raw["type"]]
      klass&.well_formed?(raw) ? klass.new(raw) : UnknownAnswer.new(raw)
    end

    # Answers by question id, each typed with Answer.from.
    def self.map(answers)
      return {} unless answers.is_a?(Hash)

      answers.each_with_object({}) { |(id, a), h| h[id] = from(a) }
    end

    def self.number?(value)
      value.is_a?(Numeric)
    end

    # A string of decimal digits, as score probabilities and legends are keyed.
    def self.index?(key)
      key.is_a?(String) && key.match?(/\A(0|[1-9][0-9]*)\z/)
    end

    def initialize(raw)
      @raw = raw
      @type = raw["type"]
    end

    # A field of the answer as the server sent it.
    def [](key)
      raw[key.to_s]
    end

    def to_h
      raw
    end
  end

  # An answer of a type this gem does not know yet. `raw` holds every field the
  # server sent, so a new question type does not break an older client.
  class UnknownAnswer < Answer; end

  # The answer to a `truth` question. An answer under the type name that
  # `/v1/systemone` uses for truth questions (STRICT_TYPE) is read the same way.
  class TruthAnswer < Answer
    # The wire name `/v1/systemone` takes for the truth type.
    STRICT_TYPE = "noul"

    # The probability that the answer is true.
    attr_reader :truth

    def self.well_formed?(raw)
      number?(raw[value_field(raw)])
    end

    def self.value_field(raw)
      raw["type"] == STRICT_TYPE ? STRICT_TYPE : "truth"
    end

    def initialize(raw)
      super
      @truth = raw[self.class.value_field(raw)]
    end
  end

  # The answer to a `choice` question.
  class ChoiceAnswer < Answer
    # The chosen option's name, exactly as sent.
    attr_reader :choice
    attr_reader :confidence
    # Probability by option name, exactly as sent.
    attr_reader :probabilities

    def self.well_formed?(raw)
      probs = raw["probabilities"]
      raw["choice"].is_a?(String) && number?(raw["confidence"]) &&
        probs.is_a?(Hash) && probs.each_value.all? { |v| number?(v) }
    end

    def initialize(raw)
      super
      @choice = raw["choice"]
      @confidence = raw["confidence"]
      @probabilities = raw["probabilities"].dup
    end
  end

  # The answer to a `score` question.
  class ScoreAnswer < Answer
    # The expected level, a number from 0 to the number of levels minus one.
    attr_reader :score
    attr_reader :confidence
    # Probability by level index (Integer).
    attr_reader :probabilities
    # Level index (Integer) to the level as it was sent.
    attr_reader :legend

    def self.well_formed?(raw)
      probs = raw["probabilities"]
      legend = raw["legend"]
      number?(raw["score"]) && number?(raw["confidence"]) &&
        probs.is_a?(Hash) && probs.all? { |k, v| index?(k) && number?(v) } &&
        legend.is_a?(Hash) && legend.each_key.all? { |k| index?(k) }
    end

    def initialize(raw)
      super
      @score = raw["score"]
      @confidence = raw["confidence"]
      @probabilities = int_keys(raw["probabilities"])
      @legend = int_keys(raw["legend"])
    end

    private

    def int_keys(map)
      map.each_with_object({}) { |(k, v), h| h[Integer(k, 10)] = v }
    end
  end

  # The answer to a `number` question.
  class NumberAnswer < Answer
    # The most probable value of the grid, the JSON number as received.
    attr_reader :number
    # The probability-weighted mean over the grid, as received.
    attr_reader :expected
    # The probability of `number`.
    attr_reader :confidence
    # Probability by grid value, keyed by the value exactly as the server
    # wrote it ("7", "3.5").
    attr_reader :probabilities

    def self.well_formed?(raw)
      probs = raw["probabilities"]
      number?(raw["number"]) && number?(raw["expected"]) && number?(raw["confidence"]) &&
        probs.is_a?(Hash) && probs.each_value.all? { |v| number?(v) }
    end

    def initialize(raw)
      super
      @number = raw["number"]
      @expected = raw["expected"]
      @confidence = raw["confidence"]
      @probabilities = raw["probabilities"].dup
    end
  end

  # What the answers to `point` and `box` questions share: a place in an
  # image. Every number is as received: integers in pixels, fractions when
  # the question asked for normalized units.
  class PlaceAnswer < Answer
    # The probability that what the instructions describe is in the image
    # at all; under a low value the place is only the best guess.
    attr_reader :present
    # The probability that the place is right if the thing is there.
    attr_reader :confidence
    # The id of the image looked in.
    attr_reader :image
    # The image's size in pixels.
    attr_reader :width, :height

    def self.well_formed?(raw)
      (self::COORDINATES + %w[present confidence width height]).all? { |k| number?(raw[k]) } && raw["image"].is_a?(String)
    end

    def initialize(raw)
      super
      @present = raw["present"]
      @confidence = raw["confidence"]
      @image = raw["image"]
      @width = raw["width"]
      @height = raw["height"]
    end
  end

  # The answer to a `point` question: the spot `x`, `y` from the top-left
  # corner of the image, `x` to the right and `y` down.
  class PointAnswer < PlaceAnswer
    COORDINATES = %w[x y].freeze

    attr_reader :x, :y

    def initialize(raw)
      super
      @x = raw["x"]
      @y = raw["y"]
    end
  end

  # The answer to a `box` question: the top-left corner `x1`, `y1` and the
  # bottom-right corner `x2`, `y2`.
  class BoxAnswer < PlaceAnswer
    COORDINATES = %w[x1 y1 x2 y2].freeze

    attr_reader :x1, :y1, :x2, :y2

    def initialize(raw)
      super
      @x1 = raw["x1"]
      @y1 = raw["y1"]
      @x2 = raw["x2"]
      @y2 = raw["y2"]
    end
  end

  private_constant :PlaceAnswer

  class Answer
    TYPES = {
      "truth" => TruthAnswer, TruthAnswer::STRICT_TYPE => TruthAnswer, "choice" => ChoiceAnswer,
      "score" => ScoreAnswer, "number" => NumberAnswer, "point" => PointAnswer, "box" => BoxAnswer
    }.freeze
  end

  # Token counts of a decision and, for a request with videos, the frames the
  # API read (an Integer) and the seconds of video they cover (a number as
  # received); each nil when the response has none.
  Usage = Struct.new(:input_tokens, :output_tokens, :video_frames, :video_seconds)

  # The result of the safety check that runs on every decision on the hosted API,
  # parsed from the `x-decisionnode-safety` response header.
  class Safety
    # The header value as received.
    attr_reader :header
    # Category name to its number, for example {"harm" => 0.031, "self_harm" => 0.004}.
    attr_reader :scores
    # The categories above the key's thresholds, in header order.
    attr_reader :flagged
    # Why the check did not run, when it did not.
    attr_reader :reason

    # Parses the header value. Returns nil when there is no header.
    def self.parse(value)
      return nil if value.nil?

      new(value.to_s.strip)
    end

    def initialize(header)
      @header = header
      @scores = {}
      @flagged = []
      @reason = nil
      if header.start_with?("unchecked")
        @checked = false
        header.split(";").drop(1).each do |param|
          key, _, val = param.strip.partition("=")
          @reason = val.strip.delete_prefix('"').delete_suffix('"') if key == "reason"
        end
      else
        @checked = true
        header.split(",").each do |member|
          member = member.strip
          next if member.empty?

          head, *params = member.split(";")
          name, _, num = head.partition("=")
          name = name.strip
          @scores[name] = parse_number(num)
          @flagged << name if params.any? { |p| %w[flagged blocked].include?(p.strip) }
        end
      end
    end

    def checked
      @checked
    end
    alias checked? checked

    def harm
      @scores["harm"]
    end

    def self_harm
      @scores["self_harm"]
    end

    def [](name)
      @scores[name.to_s]
    end

    def to_h
      return { "checked" => false, "reason" => reason } unless checked

      { "checked" => true, "harm" => nil, "self_harm" => nil }.merge(@scores).merge("flagged" => flagged)
    end

    private

    def parse_number(text)
      f = Float(text.strip)
      f
    rescue ArgumentError, TypeError
      nil
    end
  end

  # The answers to one request, with the metadata the server sent with them.
  class Decision
    include DecisionResult

    # Question id to Answer.
    attr_reader :answers
    # The resolved model version.
    attr_reader :model
    attr_reader :usage
    # From the `x-request-id` header.
    attr_reader :request_id
    # The server's processing time, from the `x-decisionnode-latency-ms` header.
    attr_reader :latency_ms
    # A Safety, or nil when the server sent no safety header.
    attr_reader :safety
    # What the API says it changed while reading the request's videos (a
    # lower rate or resolution), each sentence as sent; empty when it sent none.
    attr_reader :warnings
    # The parsed response body.
    attr_reader :raw
    # The response headers, names in lower case.
    attr_reader :headers

    def initialize(body, headers = {})
      body = {} unless body.is_a?(Hash)
      @raw = body
      @headers = headers
      @model = body["model"]
      @answers = Answer.map(body["answers"])
      usage = body["usage"].is_a?(Hash) ? body["usage"] : {}
      @usage = Usage.new(usage["input_tokens"], usage["output_tokens"],
                         usage["video_frames"].is_a?(Integer) ? usage["video_frames"] : nil,
                         usage["video_seconds"].is_a?(Numeric) ? usage["video_seconds"] : nil)
      @warnings = body["warnings"].is_a?(Array) ? body["warnings"].grep(String).freeze : [].freeze
      @request_id = headers["x-request-id"]
      @latency_ms = parse_latency(headers["x-decisionnode-latency-ms"])
      @safety = Safety.parse(headers["x-decisionnode-safety"])
    end

    # The answer to the question with this id.
    def [](id)
      answers.fetch(id.to_s) { raise KeyError, "no answer with the id #{id.to_s.inspect}" }
    end

    def key?(id)
      answers.key?(id.to_s)
    end

    private

    def parse_latency(value)
      return nil if value.nil?

      f = Float(value.strip)
      f == f.floor ? f.to_i : f
    rescue ArgumentError, TypeError
      nil
    end
  end

  # A model listed by `GET /v1/models`.
  class ModelInfo
    attr_reader :name, :description, :release_date
    # Every other field of the entry: the model's published limits, the
    # `sessions` and `batch` objects included.
    attr_reader :limits
    attr_reader :raw

    def initialize(raw)
      @raw = raw.is_a?(Hash) ? raw : {}
      @name = @raw["name"]
      @description = @raw["description"]
      @release_date = @raw["release_date"]
      @limits = @raw.reject { |k, _| %w[name description release_date].include?(k) }
    end

    # One published limit by name, for example "context_tokens", or a path
    # into a nested one: limit("sessions", "max_per_key").
    def limit(*path)
      limits.dig(*path.map(&:to_s))
    end

    # The session limits (`max_per_key`, `max_window`, `max_frame_tokens`, ...), or nil.
    def sessions
      limits["sessions"]
    end

    # The Batch API limits (`requests_per_batch`, `add_bytes`, ...), or nil.
    def batch
      limits["batch"]
    end
  end
end
