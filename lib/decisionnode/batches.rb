# frozen_string_literal: true

require "json"
require "uri"

class DecisionNode
  # A batch: every field of the batch object, by name or as `batch["field"]`.
  class Batch
    FIELDS = %w[id state counters created_at finalized_at expires_at ended_at results_url
                results_expire_at price_factor usage error].freeze
    ENDED = %w[completed failed cancelled expired].freeze

    # The batch object as received.
    attr_reader :raw

    FIELDS.each do |name|
      define_method(name) { @raw[name] }
    end

    def initialize(raw)
      @raw = raw.is_a?(Hash) ? raw : {}
    end

    def [](key)
      @raw[key.to_s]
    end

    def to_h
      @raw
    end

    # True once the batch is completed, failed, cancelled or expired.
    def ended?
      !ended_at.nil? || ENDED.include?(state)
    end

    def inspect
      "#<#{self.class.name} #{id.inspect} state=#{state.inspect}>"
    end
  end

  # One page of DecisionNode::Batches#list.
  class BatchPage
    # The batches on this page, newest first, as Batch values.
    attr_reader :batches
    attr_reader :offset, :limit, :total
    # The offset of the next page, or nil on the last page.
    attr_reader :next_offset
    attr_reader :raw

    def initialize(raw)
      @raw = raw.is_a?(Hash) ? raw : {}
      @batches = (@raw["batches"] || []).map { |b| Batch.new(b) }
      @offset = @raw["offset"]
      @limit = @raw["limit"]
      @total = @raw["total"]
      @next_offset = @raw["next_offset"]
    end

    def to_h
      @raw
    end
  end

  # One line of a batch's results.
  class BatchResult
    attr_reader :custom_id
    # The line's HTTP status (an Integer), or "expired" or "cancelled".
    attr_reader :status
    # The line's headers, names in lower case.
    attr_reader :headers
    # A Decision for a 200 line, parsed as #decide parses a response; else nil.
    attr_reader :decision
    # For an error line, the error #decide would have raised for that status
    # and body, as a value (never raised); else nil.
    attr_reader :error
    # The line as received.
    attr_reader :raw

    def initialize(raw, error_builder)
      @raw = raw.is_a?(Hash) ? raw : {}
      @custom_id = @raw["custom_id"]
      @status = @raw["status"]
      @headers = (@raw["headers"].is_a?(Hash) ? @raw["headers"] : {}).to_h { |k, v| [k.to_s.downcase, v] }
      body = @raw["body"]
      if @status == 200 && body.is_a?(Hash)
        @decision = Decision.new(body, @headers)
      elsif @status.is_a?(Integer)
        @error = error_builder.call(@status, @headers, body)
      end
    end

    def ok?
      !@decision.nil?
    end
  end

  # The Batch API: decisions at half the price, answered within 24 hours.
  # Reached as DecisionNode#batches.
  #
  #   b = dn.batches.create([{ custom_id: "t1", state: "...", questions: { ... } }])
  #   dn.batches.finalize(b.id)
  #   dn.batches.get(b.id).state
  #   dn.batches.results(b.id).each { |r| r.decision || r.error }
  #
  # A request is a Hash of #decide's arguments plus `custom_id`; its images
  # follow the client's inline threshold per line, and uploaded ones are held
  # by the batch. Every request is checked locally before anything is sent.
  #
  # `get`, `list`, `results` and `cancel` are retried as every call is.
  # `create`, `add` and `finalize` are retried only on 429 and 529, never after
  # a timeout, a lost answer or a 5xx, since a repeat could make a second draft.
  class Batches
    # The most bytes one add call carries; a larger list is split, in order.
    ADD_BYTES = 10_485_760
    NDJSON = "application/x-ndjson"

    def initialize(client)
      @client = client
    end

    def inspect
      "#<#{self.class.name}>"
    end

    # Creates a draft (`POST /v1/batches`) with these requests, or an empty
    # draft without any. Returns the Batch.
    def create(requests = [])
      lines = lines_for(requests)
      Batch.new(call("POST", "/v1/batches", lines.join, policy: :mutation, content_type: NDJSON))
    end

    # Adds requests to a draft (`POST /v1/batches/{id}/requests`), in calls of
    # at most 10 MiB each, in order. Returns the Batch after the last call.
    def add(batch_id, requests)
      lines = lines_for(requests)
      raise ArgumentError, "add needs at least one request" if lines.empty?

      path = "/v1/batches/#{segment(batch_id)}/requests"
      batch = nil
      chunks(lines).each do |chunk|
        batch = call("POST", path, chunk, policy: :mutation, content_type: NDJSON)
      end
      Batch.new(batch)
    end

    # Queues a draft to run (`POST /v1/batches/{id}/finalize`). A 409
    # `invalid_batch_state` is resolved with #get: when the batch is no longer
    # a draft (an earlier finalize went through), the batch is returned.
    def finalize(batch_id)
      Batch.new(call("POST", "/v1/batches/#{segment(batch_id)}/finalize", nil, policy: :mutation))
    rescue DecisionNodeError => e
      raise unless e.status == 409 && e.error_type == "invalid_batch_state"

      batch = get(batch_id)
      raise e if batch.state == "draft"

      batch
    end

    # `GET /v1/batches/{id}`.
    def get(batch_id)
      Batch.new(call("GET", "/v1/batches/#{segment(batch_id)}", nil))
    end

    # One page of the key's batches, newest first (`GET /v1/batches`).
    def list(offset: nil, limit: nil)
      query = {}
      query["offset"] = Integer(offset) unless offset.nil?
      query["limit"] = Integer(limit) unless limit.nil?
      path = query.empty? ? "/v1/batches" : "/v1/batches?#{URI.encode_www_form(query)}"
      BatchPage.new(call("GET", path, nil))
    end

    # The results of an ended batch (`GET /v1/batches/{id}/results`), one
    # BatchResult per request in upload order.
    def results(batch_id)
      text, = @client.__send__(:request, "GET", "/v1/batches/#{segment(batch_id)}/results", nil, raw: true)
      builder = @client.method(:error_from)
      text.each_line.filter_map do |line|
        next if line.strip.empty?

        BatchResult.new(JSON.parse(line), builder)
      end
    rescue JSON::ParserError => e
      raise ServerError.new("a results line is not JSON: #{e.message}")
    end

    # Cancels a batch (`POST /v1/batches/{id}/cancel`).
    def cancel(batch_id)
      Batch.new(call("POST", "/v1/batches/#{segment(batch_id)}/cancel", nil))
    end

    # `GET /v1/batches/{id}` with the response headers, for run_batch's waits.
    def get_with_headers(batch_id)
      body, headers, = @client.__send__(:request, "GET", "/v1/batches/#{segment(batch_id)}", nil)
      [Batch.new(body), headers]
    end

    private

    def call(method, path, body, policy: :default, content_type: nil)
      parsed, = @client.__send__(:request, method, path, body, encoded: body.is_a?(String),
                                                              policy: policy, content_type: content_type)
      parsed
    end

    def segment(batch_id)
      id = batch_id.respond_to?(:id) ? batch_id.id : batch_id
      raise ArgumentError, "a batch id is required" if id.nil? || id.to_s.empty?

      URI.encode_www_form_component(id.to_s)
    end

    def lines_for(requests)
      raise ArgumentError, "requests must be an Array of Hashes" unless requests.respond_to?(:to_a)

      list = requests.to_a
      list.each_with_index.map { |req, i| @client.__send__(:checked_line, req, i) } # every line checked first
      list.each_with_index.map { |req, i| @client.__send__(:batch_line, req, i) }
    end

    def chunks(lines)
      out = []
      current = +""
      lines.each do |line|
        if !current.empty? && current.bytesize + line.bytesize > ADD_BYTES
          out << current
          current = +""
        end
        current << line
      end
      out << current
    end
  end
end
