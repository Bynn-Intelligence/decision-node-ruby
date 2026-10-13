# frozen_string_literal: true

require "securerandom"
require "uri"

class DecisionNode
  # Collections of faces: a workspace's own, and the public ones it may use
  # (`celebrities` is an id like any other). Every call returns the API's
  # object as sent, a Hash with the API's field names; #list returns the
  # collections in the order sent.
  #
  # `create` and `enroll` send an Idempotency-Key, a new UUID for each call and
  # the same on every attempt of it, so the API creates, enrolls and bills once
  # however often the call is tried. They retry as every call does, and also
  # on a 409 `idempotency_in_progress` after its Retry-After; a 409
  # `idempotency_key_reused` is raised. `update_item` carries a key the same
  # way. Reads and deletes carry no key. An answer the API replays for a
  # repeated key is returned as sent.
  class Collections
    NAME_MAX = 80
    REFERENCE_MAX = 64
    LABEL_MAX = 128
    # The API's pattern, as its 422 names it, and the same rule matched on the
    # whole string (Ruby's ^ and $ match at line ends). An empty reference
    # fails the pattern, as the API answers it.
    REFERENCE_PATTERN = "^[A-Za-z0-9_.:-]{1,64}$"
    REFERENCE_RULE = /\A[A-Za-z0-9_.:-]{1,64}\z/
    ECHO_CHARS = 64
    METADATA_KEYS = 20
    METADATA_KEY_CHARS = 40
    METADATA_TEXT_CHARS = 500
    METADATA_KEY_RULE = /\A[a-z0-9_]{1,40}\z/
    # The value of an argument not given, so a label given as nil is sent as
    # null, which clears it.
    UNSET = Object.new.freeze
    private_constant :NAME_MAX, :REFERENCE_MAX, :LABEL_MAX, :REFERENCE_PATTERN, :REFERENCE_RULE, :ECHO_CHARS,
                     :METADATA_KEYS, :METADATA_KEY_CHARS, :METADATA_TEXT_CHARS, :METADATA_KEY_RULE, :UNSET

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
        entries << Checks.entry("literal_error", %w[body type], "Input should be 'face'", echoed(type), { "expected" => "'face'" })
      end
      entries.concat(string_entries(%w[body name], name, 1, NAME_MAX))
      raise Checks.invalid(entries) unless entries.empty?

      call("POST", "/v1/collections", { "type" => type, "name" => name }, key: SecureRandom.uuid)
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
    # image is sent as a decision sends one: a URL as given, local bytes inline
    # under the inline threshold, else uploaded. Only a URL's rules are checked
    # before sending; any other fault of the picture is the API's 422
    # `image_unreadable`. `reference` is 1 to 64 of A-Z, a-z, 0-9 and _ . : -;
    # `label`, when given, at most 128 characters. `metadata`, when given, is a
    # Hash of at most 20 keys of 1 to 40 of a-z, 0-9 and _, each value a text of
    # at most 500 characters, a number, true or false.
    def enroll(collection_id, image:, reference:, label: nil, metadata: nil)
      entries = []
      entries << Checks.entry("missing", %w[body image], "Field required", nil) if image.nil?
      entries.concat(string_entries(%w[body reference], reference, 1, REFERENCE_MAX, REFERENCE_RULE))
      entries.concat(string_entries(%w[body label], label, 1, LABEL_MAX)) unless label.nil?
      entries.concat(metadata_entries(metadata)) unless metadata.nil?
      raise Checks.invalid(entries) unless entries.empty?

      images = @client.__send__(:prepared_images, [image])
      Checks.image_url!(image.id, image.url) if image.is_a?(Image) && image.url
      path = "/v1/collections/#{segment(collection_id)}/items"
      2.times do |attempt|
        wires, placed = @client.__send__(:image_wires, images)
        body = { "image" => wires.first, "reference" => reference }
        body["label"] = label unless label.nil?
        body["metadata"] = metadata unless metadata.nil?
        begin
          # A resend after a stale upload carries a new upload id, so it is a
          # new request with its own key.
          return call("POST", path, body, key: SecureRandom.uuid)
        rescue BadRequestError => e
          raise unless attempt.zero? && !placed.empty? && Uploads::STALE_UPLOAD.include?(e.error_type)

          @client.__send__(:drop_uploads, placed)
        end
      end
    end

    # Edits an item (`PATCH /v1/collections/{id}/items/{item_id}`), sending
    # only the fields given: a `label` given as nil clears it, and `metadata`
    # replaces the item's whole object ({} clears it). The reference and the
    # label are checked as #enroll checks them. It carries an Idempotency-Key
    # and retries as #create and #enroll do. Returns the item as sent.
    def update_item(collection_id, item_id, reference: UNSET, label: UNSET, metadata: UNSET)
      entries = []
      body = {}
      unless reference.equal?(UNSET)
        entries.concat(string_entries(%w[body reference], reference, 1, REFERENCE_MAX, REFERENCE_RULE))
        body["reference"] = reference
      end
      unless label.equal?(UNSET)
        entries.concat(string_entries(%w[body label], label, 1, LABEL_MAX)) unless label.nil?
        body["label"] = label
      end
      unless metadata.equal?(UNSET)
        entries.concat(metadata_entries(metadata))
        body["metadata"] = metadata
      end
      entries << Checks.entry("missing", %w[body], "Send reference, label, metadata or any of them", nil) if body.empty?
      raise Checks.invalid(entries) unless entries.empty?

      call("PATCH", "/v1/collections/#{segment(collection_id)}/items/#{segment(item_id)}", body,
           key: SecureRandom.uuid)
    end

    # One page of a collection's items (`GET /v1/collections/{id}/items`),
    # with `offset`, `limit`, `reference` (the items of that reference) and
    # `reference_prefix` (the items whose reference starts with it) sent only
    # when given; `reference` and `reference_prefix` not both.
    def list_items(collection_id, offset: nil, limit: nil, reference: nil, reference_prefix: nil)
      Checks.list!(offset, limit)
      unless reference.nil? || reference_prefix.nil?
        Checks.usage("Send query parameter reference or reference_prefix, not both.")
      end

      query = {}
      query["offset"] = offset unless offset.nil?
      query["limit"] = limit unless limit.nil?
      { "reference" => reference, "reference_prefix" => reference_prefix }.each do |name, value|
        next if value.nil?

        reference_query!(name, value)
        query[name] = value
      end
      path = "/v1/collections/#{segment(collection_id)}/items"
      call("GET", query.empty? ? path : "#{path}?#{query.map { |k, v| "#{k}=#{URI.encode_uri_component(v.to_s)}" }.join('&')}")
    end

    # `DELETE /v1/collections/{id}/items/{item_id}`.
    def delete_item(collection_id, item_id)
      call("DELETE", "/v1/collections/#{segment(collection_id)}/items/#{segment(item_id)}")
    end

    private

    def call(method, path, body = nil, key: nil)
      return @client.__send__(:request, method, path, body).first if key.nil?

      parsed, = @client.__send__(:request, method, path, body, policy: :idempotent,
                                                               extra_headers: { "Idempotency-Key" => key })
      parsed
    end

    def segment(id)
      raise ArgumentError, "an id is required" if id.nil? || id.to_s.empty?

      URI.encode_uri_component(id.to_s)
    end

    # An item's metadata's 422 entries, as the API answers them: not a Hash,
    # more than 20 keys (that alone, before any key is read), a key not 1 to 40
    # of a-z, 0-9 and _, a text over 500 characters, a value that is not a
    # text, a number, true or false; in key order. A text's control or
    # invisible characters, a number's range and the 4 KB limit are the API's.
    def metadata_entries(metadata)
      loc = %w[body metadata]
      return [Checks.entry("value_error", loc, "Metadata is an object of keys and values.", echoed(metadata))] unless metadata.is_a?(Hash)
      if metadata.size > METADATA_KEYS
        return [Checks.entry("value_error", loc, "Metadata holds at most #{METADATA_KEYS} keys.", nil)]
      end

      metadata.each_with_object([]) do |(key, value), out|
        key = key.to_s if key.is_a?(Symbol)
        if !key.is_a?(String) || !key.match?(METADATA_KEY_RULE)
          out << Checks.entry("value_error", loc, "A metadata key is 1 to #{METADATA_KEY_CHARS} characters of a-z, 0-9 and _: \"#{shown_key(key.to_s)}\".", nil)
        elsif value.is_a?(String)
          if value.length > METADATA_TEXT_CHARS
            out << Checks.entry("value_error", loc + [key], "A metadata text is at most #{METADATA_TEXT_CHARS} characters.", echoed(value))
          end
        elsif !(value.is_a?(Integer) || value.is_a?(Float) || value == true || value == false)
          out << Checks.entry("value_error", loc + [key], "A metadata value is a text, a number or true or false.", echoed(value))
        end
      end
    end

    # A metadata key as the API's message shows it: its first 40 characters,
    # each control character as ?, then "..." when it was longer.
    def shown_key(key)
      shown = key.each_char.first(METADATA_KEY_CHARS).map { |c| c.match?(/\p{Cc}/) ? "?" : c }.join
      key.length > METADATA_KEY_CHARS ? "#{shown}..." : shown
    end

    # A `reference` or `reference_prefix` of the items list, checked as the
    # API checks it.
    def reference_query!(name, value)
      return if value.is_a?(String) && value.match?(REFERENCE_RULE)

      Checks.usage("Query parameter #{name} must be 1 to 64 characters of A-Z, a-z, 0-9, _, ., : and -, " \
                         "got #{printable(value.to_s, REFERENCE_MAX)}.")
    end

    # A caller's value as an API message echoes it: its first `most`
    # characters, any but printable ASCII as \u{hex}, then "..." when longer.
    def printable(value, most)
      shown = value.each_char.first(most).map { |c| c.ord.between?(0x20, 0x7E) ? c : "\\u{#{c.ord.to_s(16)}}" }.join
      value.length > most ? "#{shown}..." : shown
    end

    # How a collections 422 entry echoes an input, as the API does: a String
    # cut to its first 64 characters, with "..." only when it was longer; an
    # object or an array never (nil); anything else as it is.
    def echoed(value)
      case value
      when String then value.length > ECHO_CHARS ? "#{value[0, ECHO_CHARS]}..." : value
      when Hash, Array then nil
      else value
      end
    end

    # A string field's 422 entry, as the API answers it: missing, not a
    # String, too short, too long, or (with a pattern) not matching it. The
    # length is checked before the pattern, so an empty value is too short.
    def string_entries(loc, value, least, most, rule = nil, required: least.positive?)
      return required ? [Checks.entry("missing", loc, "Field required", nil)] : [] if value.nil?
      return [Checks.entry("string_type", loc, "Input should be a valid string", echoed(value))] unless value.is_a?(String)

      if value.length < least
        chars = least == 1 ? "character" : "characters"
        return [Checks.entry("string_too_short", loc, "String should have at least #{least} #{chars}", value,
                             { "min_length" => least })]
      end
      if value.length > most
        return [Checks.entry("string_too_long", loc, "String should have at most #{most} characters", echoed(value),
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
