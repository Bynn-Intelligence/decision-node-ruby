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

      klass = { "truth" => TruthAnswer, "choice" => ChoiceAnswer, "score" => ScoreAnswer }[raw["type"]]
      klass&.well_formed?(raw) ? klass.new(raw) : UnknownAnswer.new(raw)
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

  # The answer to a `truth` question.
  class TruthAnswer < Answer
    # The probability that the answer is true.
    attr_reader :truth

    def self.well_formed?(raw)
      number?(raw["truth"])
    end

    def initialize(raw)
      super
      @truth = raw["truth"]
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

  # Token counts of a decision.
  Usage = Struct.new(:input_tokens, :output_tokens)

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
    # The parsed response body.
    attr_reader :raw
    # The response headers, names in lower case.
    attr_reader :headers

    def initialize(body, headers = {})
      body = {} unless body.is_a?(Hash)
      @raw = body
      @headers = headers
      @model = body["model"]
      @answers = (body["answers"] || {}).each_with_object({}) { |(id, a), h| h[id] = Answer.from(a) }
      usage = body["usage"].is_a?(Hash) ? body["usage"] : {}
      @usage = Usage.new(usage["input_tokens"], usage["output_tokens"])
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
    # Every other field of the entry: the model's published limits.
    attr_reader :limits
    attr_reader :raw

    def initialize(raw)
      @raw = raw
      @name = raw["name"]
      @description = raw["description"]
      @release_date = raw["release_date"]
      @limits = raw.reject { |k, _| %w[name description release_date].include?(k) }
    end
  end
end
