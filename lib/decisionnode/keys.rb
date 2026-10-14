# frozen_string_literal: true

require "securerandom"
require "uri"

class DecisionNode
  # The query rules the API checks as it reads `GET /v1/usage` and
  # `GET /v1/keys`, each raised as its 400 `api_usage_error` with the API's
  # message, and the query built from what is given.
  module KeyFilters
    GRANULARITIES = %w[none hour day month].freeze
    GROUPS = %w[model channel].freeze
    SCOPES = %w[full decide keys].freeze
    STATUSES = %w[active expired revoked all].freeze
    USAGE_LIMIT_MAX = 1_000
    KEYS_LIMIT_MAX = 200
    MAX_KEY_IDS = 100
    KEY_ID_RULE = /\Akey_[0-9a-f]{32}\z/
    LABEL_NAME_RULE = /\A[a-z0-9_.-]{1,32}\z/
    LABEL_VALUE_CHARS = 64
    DEVICE_ID_CHARS = 128
    IDEMPOTENCY_KEY_CHARS = 255

    module_function

    # A usage read's period and breakdowns, each only when given.
    def period(start, finish, granularity, group_by)
      Checks.usage("granularity is none, hour, day or month.") unless granularity.nil? || GRANULARITIES.include?(granularity.to_s)
      Checks.usage("group_by is model or channel.") unless group_by.nil? || GROUPS.include?(group_by.to_s)

      [["start", start], ["end", finish], ["granularity", granularity], ["group_by", group_by]].reject { |_, v| v.nil? }
    end

    # Each label as `label=name:value`, sorted by name, so a Hash sends the
    # same query every time.
    def labels(labels)
      return [] if labels.nil?
      raise ArgumentError, "labels must be a Hash of label names to values" unless labels.is_a?(Hash)

      labels.map { |name, value| [name.is_a?(Symbol) ? name.to_s : name, value] }.sort_by { |name, _| name.to_s }.map do |name, value|
        unless name.is_a?(String) && name.match?(LABEL_NAME_RULE) && value.is_a?(String) &&
               value.length.between?(1, LABEL_VALUE_CHARS) && !value.match?(/\p{Cc}/)
          Checks.usage("A label filter is name:value, as labels are written.")
        end
        ["label", "#{name}:#{value}"]
      end
    end

    def device(device_id)
      return [] if device_id.nil?
      unless device_id.is_a?(String) && device_id.length.between?(1, DEVICE_ID_CHARS) &&
             device_id.each_char.all? { |c| c.ord.between?(0x20, 0x7E) } && !device_id.start_with?(" ")
        Checks.usage("device_id is 1 to 128 printable ASCII characters, not starting with a space.")
      end

      [["device_id", device_id]]
    end

    def status(status)
      return [] if status.nil?

      Checks.usage("status is active, expired, revoked or all.") unless STATUSES.include?(status.to_s)
      [["status", status]]
    end

    def page(limit, most, cursor)
      out = []
      unless limit.nil?
        Checks.usage("limit is a whole number from 1 to #{most}.") unless limit.is_a?(Integer) && limit.between?(1, most)
        out << ["limit", limit]
      end
      out << ["cursor", cursor] unless cursor.nil?
      out
    end

    # `GET /v1/usage`'s query, checked in the API's order; the period's own
    # rules and the cursor are the server's.
    def usage_list(start, finish, granularity, group_by, labels, device_id, key_ids, scope, status, include_empty, limit, cursor)
      query = period(start, finish, granularity, group_by) + labels(labels) + device(device_id)
      Array(key_ids).each_with_index do |key_id, i|
        Checks.usage("key_id is a key's id, key_ and 32 hex digits.") unless key_id.is_a?(String) && key_id.match?(KEY_ID_RULE)
        Checks.usage("At most 100 key_id filters.") if i == MAX_KEY_IDS
        query << ["key_id", key_id]
      end
      unless scope.nil?
        Checks.usage("scope is full, decide or keys.") unless SCOPES.include?(scope.to_s)
        query << ["scope", scope]
      end
      query.concat(status(status))
      unless include_empty.nil?
        Checks.usage("include_empty is true or false.") unless [true, false].include?(include_empty)
        query << ["include_empty", include_empty.to_s]
      end
      query + page(limit, USAGE_LIMIT_MAX, cursor)
    end

    # `GET /v1/keys`'s query, checked as the API reads it; the cursor is the
    # server's.
    def keys_list(labels, device_id, status, limit, cursor)
      labels(labels) + device(device_id) + status(status) + page(limit, KEYS_LIMIT_MAX, cursor)
    end

    # A caller's own Idempotency-Key: 1 to 255 printable ASCII characters.
    def idempotency_key!(key)
      return if key.is_a?(String) && key.length.between?(1, IDEMPOTENCY_KEY_CHARS) && key.each_char.all? { |c| c.ord.between?(0x20, 0x7E) }

      Checks.usage("Idempotency-Key must be sent once, as 1 to 255 printable ASCII characters.")
    end

    def path(path, query)
      return path if query.empty?

      "#{path}?#{query.map { |k, v| "#{k}=#{URI.encode_uri_component(v.to_s)}" }.join('&')}"
    end

    def segment(id)
      raise ArgumentError, "a key id is required" if id.nil? || id.to_s.empty?

      URI.encode_uri_component(id.to_s)
    end
  end
  private_constant :KeyFilters

  # Per-key usage: what each key used and cost over a period. A Full access
  # key reads every key of its workspace, a Manage device keys key its
  # Decisions-only keys. Every call returns the API's object as sent, a Hash
  # with the API's field names, and retries as any read.
  class KeyUsage
    def initialize(client)
      @client = client
    end

    def inspect
      "#<#{self.class.name}>"
    end

    # One key's usage (`GET /v1/keys/{key_id}/usage`). `start:` and `end:`
    # are RFC 3339 times, rounded to the hour by the API; left out, the UTC
    # month so far. `granularity:` ("none", "hour", "day" or "month") adds
    # `buckets`, and `group_by:` ("model" or "channel") `by_model` or
    # `by_channel`.
    def key(key_id, start: nil, end: nil, granularity: nil, group_by: nil)
      query = KeyFilters.period(start, binding.local_variable_get(:end), granularity, group_by)
      get(KeyFilters.path("/v1/keys/#{KeyFilters.segment(key_id)}/usage", query))
    end

    # One page of every key's usage over a period (`GET /v1/usage`):
    # `{period, as_of, items, next_cursor}`. `labels:` keeps the keys that
    # have them all, `key_ids:` (at most 100) the keys named, `scope:`
    # ("full", "decide" or "keys") and `status:` ("active", "expired",
    # "revoked" or "all") the keys of that kind or state; `include_empty:`
    # lists keys with no usage too. Pass `next_cursor` as `cursor:` for the
    # next page, until it is nil.
    def list(start:, end:, granularity: nil, group_by: nil, labels: nil, device_id: nil, key_ids: nil, scope: nil,
             status: nil, include_empty: nil, limit: nil, cursor: nil)
      query = KeyFilters.usage_list(start, binding.local_variable_get(:end), granularity, group_by, labels, device_id,
                                    key_ids, scope, status, include_empty, limit, cursor)
      get(KeyFilters.path("/v1/usage", query))
    end

    # Every key's usage over the period: #list's pages, `next_cursor`
    # followed until it is nil, their `items` in order. A page can hold fewer
    # keys than `limit`, so only the cursor says when the list is done.
    def all(start:, end:, granularity: nil, group_by: nil, labels: nil, device_id: nil, key_ids: nil, scope: nil,
            status: nil, include_empty: nil, limit: nil)
      finish = binding.local_variable_get(:end)
      items = []
      cursor = nil
      loop do
        page = list(start: start, end: finish, granularity: granularity, group_by: group_by, labels: labels,
                    device_id: device_id, key_ids: key_ids, scope: scope, status: status,
                    include_empty: include_empty, limit: limit, cursor: cursor)
        items.concat(Array(page.is_a?(Hash) ? page["items"] : nil))
        cursor = page.is_a?(Hash) ? page["next_cursor"] : nil
        return items if cursor.nil? || cursor.to_s.empty?
      end
    end

    private

    def get(path)
      @client.__send__(:request, "GET", path, nil).first
    end
  end

  # Decisions-only keys for devices, made, listed, changed and revoked with a
  # Manage device keys key. Every call returns the API's object as sent, a
  # Hash with the API's field names.
  #
  # #create sends an Idempotency-Key: the one given (one per enrollment, so a
  # retried enrollment gets the same key and secret back), else a new UUID
  # per call, the same on every attempt of it. It retries as every call does,
  # and also on a 409 `idempotency_in_progress` after its Retry-After; a 409
  # `idempotency_key_reused` is raised. The other calls retry as any call.
  class Keys
    # The value of an argument not given, so a field given as nil is sent as
    # null, which clears it.
    UNSET = Object.new.freeze
    private_constant :UNSET

    def initialize(client)
      @client = client
    end

    def inspect
      "#<#{self.class.name}>"
    end

    # Makes a Decisions-only key (`POST /v1/keys`): `{key, secret}`. The
    # secret is shown in this answer only (and again to a retry with the same
    # `idempotency_key:` within 24 hours); hand it to the device and never
    # log it. Each field is sent only when given.
    def create(name, device_id: nil, labels: nil, limits: nil, daily_spend_cap: nil, expires_at: nil,
               may_search_collections: nil, idempotency_key: nil)
      KeyFilters.idempotency_key!(idempotency_key) unless idempotency_key.nil?
      body = { "name" => name }
      { "device_id" => device_id, "labels" => labels, "limits" => limits, "daily_spend_cap" => daily_spend_cap,
        "expires_at" => expires_at, "may_search_collections" => may_search_collections }.each do |field, value|
        body[field] = value unless value.nil?
      end
      parsed, = @client.__send__(:request, "POST", "/v1/keys", body, policy: :idempotent,
                                                                 extra_headers: { "Idempotency-Key" => idempotency_key || SecureRandom.uuid })
      parsed
    end

    # One page of the workspace's Decisions-only keys, newest first:
    # `{items, next_cursor}`. `labels:` keeps the keys that have them all,
    # `status:` is "active" (the API's default), "expired", "revoked" or
    # "all", and `limit:` 1 to 200. Pass `next_cursor` as `cursor:` for the
    # next page, until it is nil.
    def list(labels: nil, device_id: nil, status: nil, limit: nil, cursor: nil)
      call("GET", KeyFilters.path("/v1/keys", KeyFilters.keys_list(labels, device_id, status, limit, cursor)))
    end

    # Every key #list finds: its pages, `next_cursor` followed until it is
    # nil, their `items` in order.
    def all(labels: nil, device_id: nil, status: nil, limit: nil)
      items = []
      cursor = nil
      loop do
        page = list(labels: labels, device_id: device_id, status: status, limit: limit, cursor: cursor)
        items.concat(Array(page.is_a?(Hash) ? page["items"] : nil))
        cursor = page.is_a?(Hash) ? page["next_cursor"] : nil
        return items if cursor.nil? || cursor.to_s.empty?
      end
    end

    # Changes a key (`PATCH /v1/keys/{id}`), sending only the fields given:
    # `labels:` replaces the key's whole set, and nil clears `labels`,
    # `limits`, `daily_spend_cap` or `expires_at`. A key's `device_id` never
    # changes. Returns the key.
    def update(key_id, name: UNSET, labels: UNSET, limits: UNSET, daily_spend_cap: UNSET, expires_at: UNSET,
               may_search_collections: UNSET)
      body = { "name" => name, "labels" => labels, "limits" => limits, "daily_spend_cap" => daily_spend_cap,
               "expires_at" => expires_at, "may_search_collections" => may_search_collections }
             .reject { |_, value| value.equal?(UNSET) }
      Checks.usage("Nothing to change.") if body.empty?

      call("PATCH", "/v1/keys/#{KeyFilters.segment(key_id)}", body)
    end

    # Revokes a key at once (`DELETE /v1/keys/{id}`): `{id, revoked}`. The
    # next call with it gets a 401; a revocation cannot be undone.
    def revoke(key_id)
      call("DELETE", "/v1/keys/#{KeyFilters.segment(key_id)}")
    end

    # Revokes every active key that has all of `labels` (and, with
    # `device_ids:`, is one of those devices), at most 10,000 a call
    # (`POST /v1/keys/revoke`): `{revoked, more}`. Call it again while `more`
    # is true. With `dry_run: true` it revokes nothing and answers
    # `{would_revoke, more}`.
    def revoke_by_labels(labels, device_ids: nil, dry_run: nil)
      body = { "labels" => labels }
      body["device_ids"] = Array(device_ids) unless device_ids.nil?
      body["dry_run"] = dry_run unless dry_run.nil?
      call("POST", "/v1/keys/revoke", body)
    end

    private

    def call(method, path, body = nil)
      @client.__send__(:request, method, path, body).first
    end
  end
end
