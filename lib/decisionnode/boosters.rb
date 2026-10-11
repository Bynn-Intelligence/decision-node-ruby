# frozen_string_literal: true

class DecisionNode
  # A booster named with settings, for the `boosters:` argument of #decide,
  # the helpers, #decide_many requests and batch requests. A booster reads the
  # request's images before the decision; its reading comes back in
  # Decision#evidence and the model sees it as evidence.
  #
  #   DecisionNode::Booster.new("ai_generated", images: ["c3d4"], require: true)
  #
  # name::    the booster's name, for example "age" or "ai_generated".
  # images::  the ids of the request's images it reads; left out, every image.
  # require:: true: a booster that fails or does not answer in time fails the
  #           request with the 529 `booster_unavailable` (an OverloadedError,
  #           retried). Left out or false: the decision runs without it.
  # options:: the booster's settings, a Hash.
  #
  # A plain name ("age") or a Hash in the API's wire form is accepted wherever
  # a Booster is. Nothing about boosters is checked before sending: the API
  # answers a malformed list, an unknown name and a booster turned off.
  class Booster
    attr_reader :name, :images, :options

    def initialize(name, images: nil, require: nil, options: nil)
      @name = name.is_a?(Symbol) ? name.to_s : name
      @images = images.is_a?(Array) ? images.dup.freeze : images
      @require = require
      @options = options.is_a?(Hash) ? options.dup.freeze : options
    end

    # Whether a failed booster fails the request, as given (nil when not given).
    def require
      @require
    end

    # The booster's object form: `images`, `require` and `options` only when given.
    def to_h
      wire = { "name" => name }
      wire["images"] = images unless images.nil?
      wire["require"] = @require unless @require.nil?
      wire["options"] = options unless options.nil?
      wire
    end

    # The booster as it is sent: its name alone when no setting is given, so
    # a list of such boosters is the plain list of names; else #to_h.
    def wire
      images.nil? && @require.nil? && options.nil? ? name : to_h
    end

    # The wire form as JSON, wherever the Booster sits in a value.
    def to_json(*args)
      wire.to_json(*args)
    end

    def inspect
      "#<#{self.class.name} #{name.inspect}>"
    end
  end

  # The status and time of one booster on a request, from the
  # `x-decisionnode-boosters` response header: `status` ("ok", "timeout",
  # "error", "skipped", or another value as sent) and `latency_ms` (an Integer,
  # or nil when the header gave none).
  BoosterStatus = Struct.new(:status, :latency_ms) do
    # The header's value as booster name to BoosterStatus, in the header's
    # order; an empty Hash when there is no header. An entry it cannot read is
    # left out; it never raises.
    def self.parse(value)
      out = {}
      return out unless value.is_a?(String)

      value.split(",").each do |item|
        name, eq, rest = item.strip.partition("=")
        name = name.strip
        next if eq.empty? || name.empty?

        status, _, ms = rest.partition(":")
        ms = ms.strip
        out[name] = new(status.strip, ms.match?(/\A[0-9]+\z/) ? Integer(ms, 10) : nil)
      end
      out
    end
  end

  # What one booster found on a request, an entry of Decision#evidence.
  class Evidence
    # The version of the booster that read, for example "age-v3".
    attr_reader :version
    # "ok", "timeout" (no answer in time), "error", "skipped" (none of the
    # request's images is one it reads), or another value as sent.
    attr_reader :status
    # How long the booster took, in milliseconds, as sent.
    attr_reader :latency_ms
    # The calls of this booster billed on this request, or nil when the server
    # did not send it.
    attr_reader :billed_calls
    # One reading per image the booster was to read: an AgeReading, an
    # AiGeneratedReading or an UnknownReading. A picture it did not read (it
    # timed out or failed) or could not decode (`readable` false) is an
    # UnknownReading holding those fields; `status` says why.
    attr_reader :results
    # The entry as received.
    attr_reader :raw

    # The `evidence` of a response body as booster name to Evidence, in the
    # body's order, or nil when the body has none.
    def self.map(evidence)
      return nil unless evidence.is_a?(Hash)

      evidence.each_with_object({}) { |(name, entry), h| h[name] = new(name, entry) }
    end

    def initialize(booster, raw)
      @raw = raw
      entry = raw.is_a?(Hash) ? raw : {}
      @version = entry["version"].is_a?(String) ? entry["version"] : nil
      @status = entry["status"].is_a?(String) ? entry["status"] : nil
      @latency_ms = entry["latency_ms"].is_a?(Numeric) ? entry["latency_ms"] : nil
      @billed_calls = entry["billed_calls"].is_a?(Integer) ? entry["billed_calls"] : nil
      results = entry["results"].is_a?(Array) ? entry["results"] : []
      @results = results.map { |r| Reading.from(booster, r) }.freeze
    end

    def to_h
      raw
    end
  end

  # The base of every booster reading. `raw` holds every field the server sent.
  class Reading
    # The id of the image read, or nil when the server sent none.
    attr_reader :image
    attr_reader :raw

    # The typed reading for a booster this gem knows, when every field is
    # present and of the right type; an UnknownReading holding the raw fields
    # otherwise, so a new booster or a malformed reading never fails the decision.
    def self.from(booster, raw)
      klass = KINDS[booster]
      return UnknownReading.new({ "value" => raw }) unless raw.is_a?(Hash)

      klass&.well_formed?(raw) ? klass.new(raw) : UnknownReading.new(raw)
    end

    def self.number?(value)
      value.is_a?(Numeric)
    end

    def initialize(raw)
      @raw = raw
      @image = raw.is_a?(Hash) && raw["image"].is_a?(String) ? raw["image"] : nil
    end

    # A field of the reading as the server sent it.
    def [](key)
      raw.is_a?(Hash) ? raw[key.to_s] : nil
    end

    def to_h
      raw
    end
  end

  # A reading of a booster this gem does not know, or one with a field
  # missing or of the wrong type. `raw` holds it as received (a reading that
  # is not an object as `{"value" => reading}`).
  class UnknownReading < Reading; end

  # A reading of the `age` booster: the age of the largest face in the image.
  # With `faces` 0 the image shows no face and the age fields are nil.
  class AgeReading < Reading
    INTEGER_FIELDS = %w[age_years low high].freeze
    private_constant :INTEGER_FIELDS

    # How many faces were found; the largest is read.
    attr_reader :faces
    # The age in years, and the range `low` to `high`.
    attr_reader :age_years, :low, :high
    # From 0 to 1.
    attr_reader :confidence

    def self.well_formed?(raw)
      faces = raw["faces"]
      return false unless raw["image"].is_a?(String) && faces.is_a?(Integer) && !faces.negative?

      # With no face the age fields are left out; with one, each is required.
      INTEGER_FIELDS.all? { |k| raw[k].is_a?(Integer) || (raw[k].nil? && faces.zero?) } &&
        (number?(raw["confidence"]) || (raw["confidence"].nil? && faces.zero?))
    end

    def initialize(raw)
      super
      @faces = raw["faces"]
      @age_years = raw["age_years"]
      @low = raw["low"]
      @high = raw["high"]
      @confidence = raw["confidence"]
    end
  end

  # The likeliest generator of an AiGeneratedReading: its `name` and `probability`.
  TopGenerator = Struct.new(:name, :probability)

  # A reading of the `ai_generated` booster: how likely the image was made by
  # an image generator, and who signed its Content Credentials (C2PA) if it
  # carries any.
  class AiGeneratedReading < Reading
    # The probability that the image was made by a generator, from 0 to 1.
    attr_reader :generated
    # From 0 to 1.
    attr_reader :confidence
    # "inference" (read from the pixels), "c2pa" (the file's Content
    # Credentials say so), or another value as sent.
    attr_reader :method
    # The likeliest generator, a TopGenerator, when the reading says the image
    # is likely generated; nil otherwise, and always on a "c2pa" reading.
    attr_reader :top_generator
    # Who signed the file's Content Credentials when they are trusted; nil
    # otherwise.
    attr_reader :c2pa_signer
    # "untrusted" when the file carries Content Credentials that validate but
    # are not trusted (they name no signer and change nothing in the reading),
    # another value as sent, or nil when the reading has none.
    attr_reader :c2pa

    def self.well_formed?(raw)
      top = raw["top_generator"]
      raw["image"].is_a?(String) && number?(raw["generated"]) && number?(raw["confidence"]) &&
        raw["method"].is_a?(String) &&
        # top_generator and c2pa_signer are always sent, null when unset; c2pa
        # only when the file's Content Credentials are not trusted.
        raw.key?("top_generator") && raw.key?("c2pa_signer") &&
        (top.nil? || (top.is_a?(Hash) && top["name"].is_a?(String) && number?(top["probability"]))) &&
        (raw["c2pa_signer"].nil? || raw["c2pa_signer"].is_a?(String)) &&
        (raw["c2pa"].nil? || raw["c2pa"].is_a?(String))
    end

    def initialize(raw)
      super
      @generated = raw["generated"]
      @confidence = raw["confidence"]
      @method = raw["method"]
      top = raw["top_generator"]
      @top_generator = top && TopGenerator.new(top["name"], top["probability"])
      @c2pa_signer = raw["c2pa_signer"]
      @c2pa = raw["c2pa"]
    end
  end

  # A reading of the `ocr` booster: the text the image shows, in reading
  # order, or the answer to the booster's `prompt` option.
  class OcrReading < Reading
    # The text read; empty when the image shows none, which is a reading, not
    # a failure.
    attr_reader :text
    # true when the reading was cut at the model's context limit.
    attr_reader :truncated

    def self.well_formed?(raw)
      raw["image"].is_a?(String) && raw["text"].is_a?(String) &&
        [true, false].include?(raw["truncated"])
    end

    def initialize(raw)
      super
      @text = raw["text"]
      @truncated = raw["truncated"]
    end
  end

  # A face's box: its corners `x1`, `y1` (top left) and `x2`, `y2` (bottom
  # right), the numbers as sent: pixels of the image, or fractions of its
  # width and height when every place question of the request asks for
  # normalized units.
  FaceBox = Struct.new(:x1, :y1, :x2, :y2) do
    def self.well_formed?(raw)
      raw.is_a?(Hash) && %w[x1 y1 x2 y2].all? { |k| raw[k].is_a?(Numeric) }
    end

    def self.from(raw)
      new(raw["x1"], raw["y1"], raw["x2"], raw["y2"])
    end
  end

  # One face a `face_detection` reading found: its `box` (a FaceBox) and its
  # `confidence`, from 0 to 1.
  FaceDetection = Struct.new(:box, :confidence)

  # One face a `wanted_person` reading matched: its `box` (a FaceBox), the
  # match `score` from 0 to 1, and `reference`, the id of the list entry it
  # matched (never a name or other personal detail).
  WantedMatch = Struct.new(:box, :score, :reference)

  # The faces of a face reading, checked alike for both boosters.
  module FaceReadings
    module_function

    def counted?(raw)
      raw["image"].is_a?(String) && raw["faces"].is_a?(Integer) && !raw["faces"].negative?
    end

    def list?(raw, key)
      raw[key].is_a?(Array) && raw[key].all? { |entry| entry.is_a?(Hash) && FaceBox.well_formed?(entry["box"]) && yield(entry) }
    end
  end
  private_constant :FaceReadings

  # A reading of the `face_detection` booster: how many faces the image
  # shows, and each face's box and confidence.
  class FaceDetectionReading < Reading
    # How many faces were found; it can be more than the faces listed, which
    # are at most 64.
    attr_reader :faces
    # The faces found, in the order sent: each a FaceDetection.
    attr_reader :detections

    def self.well_formed?(raw)
      FaceReadings.counted?(raw) && FaceReadings.list?(raw, "detections") { |d| number?(d["confidence"]) }
    end

    def initialize(raw)
      super
      @faces = raw["faces"]
      @detections = raw["detections"].map { |d| FaceDetection.new(FaceBox.from(d["box"]), d["confidence"]) }.freeze
    end
  end

  # A reading of the `wanted_person` booster: how many faces it checked, and
  # each face that matched an entry of the workspace's list.
  class WantedPersonReading < Reading
    # How many faces were checked.
    attr_reader :faces
    # The faces that matched, in the order sent: each a WantedMatch. Empty
    # when none did.
    attr_reader :matches

    def self.well_formed?(raw)
      FaceReadings.counted?(raw) &&
        FaceReadings.list?(raw, "matches") { |m| number?(m["score"]) && m["reference"].is_a?(String) }
    end

    def initialize(raw)
      super
      @faces = raw["faces"]
      @matches = raw["matches"].map { |m| WantedMatch.new(FaceBox.from(m["box"]), m["score"], m["reference"]) }.freeze
    end
  end

  class Reading
    KINDS = {
      "age" => AgeReading,
      "ai_generated" => AiGeneratedReading,
      "face_detection" => FaceDetectionReading,
      "wanted_person" => WantedPersonReading,
      "ocr" => OcrReading
    }.freeze
  end
end
