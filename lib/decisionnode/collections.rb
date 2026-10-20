# frozen_string_literal: true

require "securerandom"
require "uri"

class DecisionNode
  # Collections of faces, a workspace's own and the public ones it may use
  # (`celebrities` is an id like any other), and knowledge bases: collections
  # of type "text" holding a workspace's own documents, which the `knowledge`
  # booster reads. Every call returns the API's object as sent, a Hash with
  # the API's field names; #list returns the collections in the order sent.
  # One Hash shape serves both kinds, told apart by its "type".
  #
  # `create` and `enroll` send an Idempotency-Key, a new UUID for each call and
  # the same on every attempt of it, so the API creates, enrolls and bills once
  # however often the call is tried. They retry as every call does, and also
  # on a 409 `idempotency_in_progress` after its Retry-After; a 409
  # `idempotency_key_reused` is raised. `update_item` carries a key the same
  # way, as do #add_document and #replace_document. Reads and deletes carry
  # no key. An answer the API replays for a repeated key is returned as sent.
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
    SCOPE_KEY_PATTERN = "^[a-z0-9_]{1,40}$"
    SCOPE_KEY_RULE = /\A[a-z0-9_]{1,40}\z/
    TITLE_MAX = 200
    PIN_RANK_MAX = 1_000
    # wait_until_ready: the longest wait between reads, and how much longer
    # each wait is than the one before.
    POLL_CAP = 10.0
    POLL_GROWTH = 1.5
    MIN_POLL_INTERVAL = 0.1
    # list_items' search text, in characters; its orders; and how much of a
    # wrong order the API's message echoes.
    Q_MAX = 200
    SORTS = %w[newest oldest title].freeze
    SORT_ECHO = 16
    # The value of an argument not given, so a label given as nil is sent as
    # null, which clears it.
    UNSET = Object.new.freeze
    private_constant :NAME_MAX, :REFERENCE_MAX, :LABEL_MAX, :REFERENCE_PATTERN, :REFERENCE_RULE, :ECHO_CHARS,
                     :METADATA_KEYS, :METADATA_KEY_CHARS, :METADATA_TEXT_CHARS, :METADATA_KEY_RULE, :UNSET,
                     :SCOPE_KEY_PATTERN, :SCOPE_KEY_RULE, :TITLE_MAX, :PIN_RANK_MAX, :POLL_CAP, :POLL_GROWTH,
                     :MIN_POLL_INTERVAL, :Q_MAX, :SORTS, :SORT_ECHO

    def initialize(client)
      @client = client
    end

    def inspect
      "#<#{self.class.name}>"
    end

    # Creates a collection (`POST /v1/collections`). `type` is "face" (faces)
    # or "text" (a knowledge base); `name` is 1 to 80 characters. A knowledge
    # base may take a `scope_key`, 1 to 40 of a-z, 0-9 and _, fixed for its
    # life: the metadata key whose value scopes a document to, say, one
    # mission. It is sent only when given.
    def create(name:, type: "face", scope_key: nil)
      type = type.to_s if type.is_a?(Symbol)
      entries = []
      unless %w[face text].include?(type)
        entries << Checks.entry("literal_error", %w[body type], "Input should be 'face' or 'text'", echoed(type),
                                { "expected" => "'face' or 'text'" })
      end
      entries.concat(string_entries(%w[body name], name, 1, NAME_MAX))
      unless scope_key.nil? || (scope_key.is_a?(String) && scope_key.match?(SCOPE_KEY_RULE))
        entries << Checks.entry("string_pattern_mismatch", %w[body scope_key],
                                "String should match pattern '#{SCOPE_KEY_PATTERN}'", echoed(scope_key))
      end
      raise Checks.invalid(entries) unless entries.empty?

      body = { "type" => type, "name" => name }
      body["scope_key"] = scope_key unless scope_key.nil?
      call("POST", "/v1/collections", body, key: SecureRandom.uuid)
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

    # `DELETE /v1/collections/{id}`. A knowledge base answers
    # `{"id", "deleted" => true}` once purged within 10 s, else
    # `{"id", "status" => "purging"}` while the purge finishes in the
    # background; both are success.
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
    # replaces the item's whole object ({} clears it). A document also takes
    # `pinned`, `pin_rank` (0 to 1,000) and `title` (1 to 200 characters):
    # each is applied at once, never re-embedded or billed, except a new title,
    # which makes a new version. The reference and the label are checked as
    # #enroll checks them. It carries an Idempotency-Key and retries as
    # #create and #enroll do. Returns the item as sent.
    def update_item(collection_id, item_id, reference: UNSET, label: UNSET, metadata: UNSET, pinned: UNSET,
                    pin_rank: UNSET, title: UNSET)
      given = { "reference" => reference, "label" => label, "metadata" => metadata, "pinned" => pinned,
                "pin_rank" => pin_rank, "title" => title }.reject { |_, v| v.equal?(UNSET) }
      entries = document_entries(given)
      entries << Checks.entry("missing", %w[body], "Send reference, label, metadata or any of them", nil) if given.empty?
      raise Checks.invalid(entries) unless entries.empty?

      call("PATCH", "/v1/collections/#{segment(collection_id)}/items/#{segment(item_id)}", given,
           key: SecureRandom.uuid)
    end

    # Adds a document to a knowledge base (`POST /v1/collections/{id}/items`)
    # and returns the item as sent: "queued", or with `wait: true` (the
    # server holds the call up to 10 s) "ready" once it is, else as it stands.
    #
    #   dn.collections.add_document(kb, document: DecisionNode::Document.new(path: "policy.pdf"), wait: true)
    #
    # document:: a DecisionNode::Document. A text, and a text or Markdown file
    #            under the client's inline threshold, are sent inline; any
    #            other file is uploaded first and named by its upload id.
    # title::    1 to 200 characters; required for a text, else a file's name
    #            without its extension by default.
    # reference, label, metadata:: as #enroll's. The knowledge base's scope
    #            key in `metadata` scopes the document; without it the
    #            document is global.
    # pinned::   true: always given to a request that names the knowledge base.
    # pin_rank:: 0 to 1,000, the order of pinned documents, lowest first.
    #
    # Each field is sent only when given. It carries an Idempotency-Key, a new
    # UUID for each call and the same on every attempt of it. An upload this
    # call made that the API calls stale is uploaded again and the call sent
    # once more, with a new key; an upload id you gave is never re-uploaded.
    def add_document(collection_id, document:, title: nil, reference: nil, pinned: nil, pin_rank: nil, label: nil,
                     metadata: nil, wait: false)
      fields = { "title" => title, "reference" => reference, "pinned" => pinned, "pin_rank" => pin_rank,
                 "label" => label, "metadata" => metadata }.compact
      document_write("POST", "/v1/collections/#{segment(collection_id)}/items", document, fields, wait)
    end

    # Replaces a document whole (`PUT /v1/collections/{id}/items/{item_id}`),
    # with #add_document's arguments. A new text, format or title is a new
    # version, the old one serving until the new one is ready; the same text
    # again changes nothing. Returns the item as sent.
    def replace_document(collection_id, item_id, document:, title: nil, reference: nil, pinned: nil, pin_rank: nil,
                         label: nil, metadata: nil, wait: false)
      fields = { "title" => title, "reference" => reference, "pinned" => pinned, "pin_rank" => pin_rank,
                 "label" => label, "metadata" => metadata }.compact
      document_write("PUT", "/v1/collections/#{segment(collection_id)}/items/#{segment(item_id)}", document, fields,
                     wait)
    end

    # One item (`GET /v1/collections/{id}/items/{item_id}`); with
    # `include_text: true` a document's stored text too (nil while no version
    # serves). Byte offsets in chunks and passages index that text's UTF-8 bytes.
    def get_item(collection_id, item_id, include_text: false)
      path = "/v1/collections/#{segment(collection_id)}/items/#{segment(item_id)}"
      call("GET", include_text == true ? "#{path}?include=text" : path)
    end

    # One page of a document's live chunks
    # (`GET /v1/collections/{id}/items/{item_id}/chunks`), `offset` and `limit`
    # (1 to 100) sent only when given.
    def list_chunks(collection_id, item_id, offset: nil, limit: nil)
      Checks.list!(offset, limit)
      query = { "offset" => offset, "limit" => limit }.compact
      path = "/v1/collections/#{segment(collection_id)}/items/#{segment(item_id)}/chunks"
      call("GET", query.empty? ? path : "#{path}?#{URI.encode_www_form(query)}")
    end

    # Deletes every failed document of a knowledge base
    # (`DELETE /v1/collections/{id}/items?status=failed`) and returns the
    # answer as sent, `{"deleted" => n}`.
    def delete_failed(collection_id)
      call("DELETE", "/v1/collections/#{segment(collection_id)}/items?status=failed")
    end

    # Waits on the client for documents to be ingested. With an `item_id` it
    # reads the item until its status is "ready" or "failed" and returns it,
    # whichever it is (a failed item says why in its "error"). Without one it
    # reads the knowledge base until no document is queued or processing and
    # returns it.
    #
    # The first read is made at once; then it waits `poll_interval` seconds
    # (at least 0.1, default 1), half as long again after each read up to 10
    # s. Each read retries as any call does, after the Retry-After of a 429 or
    # 529. Past `timeout` seconds (default 300) it raises
    # DecisionNode::TimeoutError.
    def wait_until_ready(collection_id, item_id = nil, timeout: 300, poll_interval: 1.0)
      unless poll_interval.is_a?(Numeric) && poll_interval.finite? && poll_interval >= MIN_POLL_INTERVAL
        raise ArgumentError, "poll_interval must be at least #{MIN_POLL_INTERVAL} seconds, got #{poll_interval.inspect}"
      end
      unless timeout.is_a?(Numeric) && timeout.positive?
        raise ArgumentError, "timeout must be a number of seconds above 0, got #{timeout.inspect}"
      end

      interval = poll_interval.to_f
      waited = 0.0
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      loop do
        found = item_id.nil? ? get(collection_id) : get_item(collection_id, item_id)
        return found if settled?(found, item_id)

        elapsed = [waited, Process.clock_gettime(Process::CLOCK_MONOTONIC) - started].max
        if elapsed >= timeout
          what = item_id.nil? ? "the documents of #{collection_id} were" : "the document #{item_id} was"
          raise TimeoutError, "#{what} not ready within #{timeout} s"
        end

        # The last wait ends at the timeout, for one more read.
        wait = [interval, timeout - elapsed].min
        @client.__send__(:pause, wait)
        waited += wait
        interval = [interval * POLL_GROWTH, POLL_CAP].min
      end
    end

    # Retrieves passages without a decision (`POST /v1/collections/{id}/search`),
    # billed as one knowledge call (a full-scope key). `query` is required;
    # `scope`, `match`, `filter`, `top_k`, `pinned` and `max_tokens` (an
    # Integer or "auto") are sent only when given, as given, as the knowledge
    # booster's options. Returns a KnowledgeReading with every passage's text
    # (an UnknownReading holding the answer when it has a field missing or of
    # the wrong type).
    def search(collection_id, query:, scope: nil, match: nil, filter: nil, top_k: nil, pinned: nil, max_tokens: nil)
      body = { "query" => query, "scope" => scope, "match" => match, "filter" => filter, "top_k" => top_k,
               "pinned" => pinned, "max_tokens" => max_tokens }.reject { |k, v| v.nil? && k != "query" }
      Reading.from("knowledge", call("POST", "/v1/collections/#{segment(collection_id)}/search", body))
    end

    # One page of a collection's items (`GET /v1/collections/{id}/items`),
    # with `offset`, `limit`, `reference` (the items of that reference),
    # `reference_prefix` (the items whose reference starts with it) sent only
    # when given; `reference` and `reference_prefix` not both. A knowledge
    # base also takes `q` (1 to 200 characters, matched without regard to
    # case against a document's title, file name or reference) and `sort`
    # ("newest", "oldest" or "title"), each sent only when given.
    def list_items(collection_id, offset: nil, limit: nil, reference: nil, reference_prefix: nil, q: nil, sort: nil)
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
      sort = sort.to_s if sort.is_a?(Symbol)
      unless q.nil? || (q.is_a?(String) && q.length.between?(1, Q_MAX))
        Checks.usage("Query parameter q must be 1 to #{Q_MAX} characters.")
      end
      unless sort.nil? || SORTS.include?(sort)
        Checks.usage("Query parameter sort must be newest, oldest or title, got #{printable(sort.to_s, SORT_ECHO)}.")
      end
      query["q"] = q unless q.nil?
      query["sort"] = sort unless sort.nil?
      path = "/v1/collections/#{segment(collection_id)}/items"
      call("GET", query.empty? ? path : "#{path}?#{query.map { |k, v| "#{k}=#{URI.encode_uri_component(v.to_s)}" }.join('&')}")
    end

    # `DELETE /v1/collections/{id}/items/{item_id}`.
    def delete_item(collection_id, item_id)
      call("DELETE", "/v1/collections/#{segment(collection_id)}/items/#{segment(item_id)}")
    end

    private

    def call(method, path, body = nil, key: nil, timeout: nil)
      return @client.__send__(:request, method, path, body, timeout: timeout).first if key.nil?

      parsed, = @client.__send__(:request, method, path, body, policy: :idempotent, timeout: timeout,
                                                               extra_headers: { "Idempotency-Key" => key })
      parsed
    end

    # Whether wait_until_ready may stop: an item ready or failed, or a
    # knowledge base with nothing queued or processing.
    def settled?(found, item_id)
      return false unless found.is_a?(Hash)
      return %w[ready failed].include?(found["status"]) unless item_id.nil?

      counts = found["status_counts"].is_a?(Hash) ? found["status_counts"] : {}
      %w[queued processing].all? { |k| counts[k].nil? || counts[k] == 0 }
    end

    # An item write: the fields checked, the document read (and uploaded when
    # it is not sent inline), then the call with its own Idempotency-Key.
    def document_write(method, path, document, fields, wait)
      raise ArgumentError, "document must be a DecisionNode::Document, got #{document.class}" unless document.is_a?(Document)

      item = document_entries(fields.slice("reference", "pin_rank", "label", "metadata", "pinned"))
      title = fields.key?("title") ? document_entries(fields.slice("title")) : nil
      entries = []
      if document.text?
        entries.concat(title || [missing_title])
        entries << Checks.entry("string_too_short", %w[body text], "The text is empty", "") if document.text.empty?
        unless document.format.nil? || Document::FORMATS.include?(document.format)
          entries << Checks.entry("literal_error", %w[body format], "Input should be 'markdown' or 'text'",
                                  echoed(document.format))
        end
        raise Checks.invalid(entries + item) unless entries.empty? && item.empty?
      end
      # A file's own faults (its type, size) come before the fields'.
      loaded = document.load
      inline = inline_text(loaded)
      unless document.text?
        entries.concat(title || (inline && loaded.filename.nil? ? [missing_title] : []))
        raise Checks.invalid(entries + item) unless entries.empty? && item.empty?
      end

      path = "#{path}?wait=true" if wait == true
      timeout = @client.__send__(:write_timeout, wait == true)
      return call(method, path, inline_body(loaded, inline, fields), key: SecureRandom.uuid, timeout: timeout) if inline

      2.times do |attempt|
        upload_id = loaded.kind == :upload ? loaded.upload_id : @client.__send__(:upload_knowledge, [loaded]).first
        body = { "upload_id" => upload_id }
        body["title"] = fields["title"] if fields.key?("title")
        body.merge!(fields.except("title"))
        begin
          # A resend after a stale upload names a new upload, so it is a new
          # request with its own key.
          return call(method, path, body, key: SecureRandom.uuid, timeout: timeout)
        rescue BadRequestError => e
          raise unless attempt.zero? && loaded.kind == :file && Uploads::STALE_UPLOAD.include?(e.error_type)
        end
      end
    end

    # A text, or a text or Markdown file whose bytes total under the client's
    # inline threshold and read as UTF-8 without a NUL: the text and its
    # format. nil for anything to upload.
    def inline_text(loaded)
      return [loaded.text, loaded.format] if loaded.kind == :text
      return nil unless loaded.kind == :file && %w[text/plain text/markdown].include?(loaded.content_type)
      return nil unless loaded.data.bytesize < @client.inline_threshold

      text = loaded.data.dup.force_encoding(Encoding::UTF_8)
      return nil unless text.valid_encoding? && !text.include?("\0")

      [text, loaded.content_type == "text/markdown" ? "markdown" : "text"]
    end

    # The body of a document sent inline: its title (a file's name without its
    # extension when none is given), its text and format, then the fields.
    def inline_body(loaded, inline, fields)
      text, format = inline
      body = { "title" => fields.fetch("title") { Document.stem(loaded.filename) }, "text" => text }
      body["format"] = format unless format.nil?
      body.merge(fields.except("title"))
    end

    def missing_title
      Checks.entry("missing", %w[body title], "Field required", nil)
    end

    # The 422 entries of a document's fields, in the order given: the title
    # (1 to 200 characters once trimmed), `pinned` (true or false) and
    # `pin_rank` (an Integer from 0 to 1,000), and the reference, the label and
    # the metadata as #enroll checks them.
    def document_entries(fields)
      entries = []
      fields.each do |name, value|
        case name
        when "title"
          next if value.is_a?(String) && value.strip.length.between?(1, TITLE_MAX)

          entries << Checks.entry("string_too_long", %w[body title], "A title is 1 to #{TITLE_MAX} characters", echoed(value))
        when "reference"
          entries.concat(string_entries(%w[body reference], value, 1, REFERENCE_MAX, REFERENCE_RULE))
        when "pinned"
          next if [true, false].include?(value)

          entries << Checks.entry("bool_type", %w[body pinned], "Input should be a valid boolean", echoed(value))
        when "pin_rank"
          next if value.is_a?(Integer) && value.between?(0, PIN_RANK_MAX)

          entries << Checks.entry("int_range", %w[body pin_rank], "Input should be an integer from 0 to #{PIN_RANK_MAX}",
                                  echoed(value))
        when "label"
          entries.concat(string_entries(%w[body label], value, 1, LABEL_MAX)) unless value.nil?
        when "metadata"
          entries.concat(metadata_entries(value))
        end
      end
      entries
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
