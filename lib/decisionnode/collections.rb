# frozen_string_literal: true

require "uri"

class DecisionNode
  # Collections of faces: a workspace's own, and the public ones it may use
  # (`celebrities` is an id like any other). Every call returns the API's
  # object as sent, a Hash with the API's field names; #list returns the
  # collections in the order sent.
  #
  # `create` and `enroll` are retried only on 429 and 529, as a batch's create
  # is: a retried enrollment would enroll the face twice and bill it twice.
  # Reads and deletes are retried as every call is.
  class Collections
    NAME_MAX = 80
    REFERENCE_MAX = 64
    LABEL_MAX = 128
    # The API's pattern, as its 422 names it, and the same rule matched on the
    # whole string (Ruby's ^ and $ match at line ends).
    REFERENCE_PATTERN = "^[A-Za-z0-9_.:-]+$"
    REFERENCE_RULE = /\A[A-Za-z0-9_.:-]+\z/
    private_constant :NAME_MAX, :REFERENCE_MAX, :LABEL_MAX, :REFERENCE_PATTERN, :REFERENCE_RULE

    def initialize(client)
      @client = client
    end

    def inspect
      "#<#{self.class.name}>"
    end

    # Creates a collection (`POST /v1/collections`). `type` is "face", the
    # one type there is; `name` is 1 to 80 characters.
    def create(name:, type: "face")
      type = type.to_s if type.is_a?(Symbol)
      entries = []
      unless type == "face"
        entries << Checks.entry("literal_error", %w[body type], "Input should be 'face'", type, { "expected" => "'face'" })
      end
      entries.concat(string_entries(%w[body name], name, 1, NAME_MAX))
      raise Checks.invalid(entries) unless entries.empty?

      call("POST", "/v1/collections", { "type" => type, "name" => name }, policy: :mutation)
    end

    # The workspace's collections, then the public ones it may use
    # (`GET /v1/collections`), as an Array in the order sent.
    def list
      body = call("GET", "/v1/collections")
      body.is_a?(Hash) ? body["collections"] : body
    end

    # `GET /v1/collections/{id}`.
    def get(collection_id)
      call("GET", "/v1/collections/#{segment(collection_id)}")
    end

    # `DELETE /v1/collections/{id}`.
    def delete(collection_id)
      call("DELETE", "/v1/collections/#{segment(collection_id)}")
    end

    # Enrolls one face from one image (`POST /v1/collections/{id}/items`). The
    # image is checked and sent as a decision sends one: a URL as given, local
    # bytes inline under the inline threshold, else uploaded. `reference` is
    # 1 to 64 of A-Z, a-z, 0-9 and _ . : -; `label`, when given, at most 128
    # characters.
    def enroll(collection_id, image:, reference:, label: nil)
      entries = []
      entries << Checks.entry("missing", %w[body image], "Field required", { "reference" => reference }) if image.nil?
      entries.concat(string_entries(%w[body reference], reference, 1, REFERENCE_MAX, REFERENCE_RULE))
      entries.concat(string_entries(%w[body label], label, 0, LABEL_MAX)) unless label.nil?
      raise Checks.invalid(entries) unless entries.empty?

      images = @client.__send__(:prepared_images, [image])
      Checks.images!(images, limits: @client.__send__(:limits_for, nil))
      path = "/v1/collections/#{segment(collection_id)}/items"
      2.times do |attempt|
        wires, placed = @client.__send__(:image_wires, images)
        body = { "image" => wires.first, "reference" => reference }
        body["label"] = label unless label.nil?
        begin
          return call("POST", path, body, policy: :mutation)
        rescue BadRequestError => e
          raise unless attempt.zero? && !placed.empty? && Uploads::STALE_UPLOAD.include?(e.error_type)

          @client.__send__(:drop_uploads, placed)
        end
      end
    end

    # One page of a collection's items (`GET /v1/collections/{id}/items`),
    # with `offset` and `limit` sent only when given.
    def list_items(collection_id, offset: nil, limit: nil)
      Checks.list!(offset, limit)
      query = {}
      query["offset"] = offset unless offset.nil?
      query["limit"] = limit unless limit.nil?
      path = "/v1/collections/#{segment(collection_id)}/items"
      call("GET", query.empty? ? path : "#{path}?#{URI.encode_www_form(query)}")
    end

    # `DELETE /v1/collections/{id}/items/{item_id}`.
    def delete_item(collection_id, item_id)
      call("DELETE", "/v1/collections/#{segment(collection_id)}/items/#{segment(item_id)}")
    end

    private

    def call(method, path, body = nil, policy: :default)
      parsed, = @client.__send__(:request, method, path, body, policy: policy)
      parsed
    end

    def segment(id)
      raise ArgumentError, "an id is required" if id.nil? || id.to_s.empty?

      URI.encode_uri_component(id.to_s)
    end

    # A string field's 422 entry, as the API answers it: missing, not a
    # String, too short, too long, or (with a pattern) not matching it.
    def string_entries(loc, value, least, most, rule = nil)
      return least.positive? ? [Checks.entry("missing", loc, "Field required", nil)] : [] if value.nil?
      return [Checks.entry("string_type", loc, "Input should be a valid string", value)] unless value.is_a?(String)

      if value.length < least
        chars = least == 1 ? "character" : "characters"
        return [Checks.entry("string_too_short", loc, "String should have at least #{least} #{chars}", value,
                             { "min_length" => least })]
      end
      if value.length > most
        return [Checks.entry("string_too_long", loc, "String should have at most #{most} characters", value,
                             { "max_length" => most })]
      end
      if rule && !value.match?(rule)
        return [Checks.entry("string_pattern_mismatch", loc, "String should match pattern '#{REFERENCE_PATTERN}'", value,
                             { "pattern" => REFERENCE_PATTERN })]
      end
      []
    end
  end
end
