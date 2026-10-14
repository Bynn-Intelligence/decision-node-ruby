# frozen_string_literal: true

require "test_helper"

# Device keys (/v1/keys) and per-key usage: each call's request, the
# Idempotency-Key and retries of create, the local checks; and the spend
# cap's 429, never retried.
class KeysTest < Minitest::Test
  include ClientHelpers

  KEY_ID = "key_7c2e9a41b0d34f6e8a5c1d2b3e4f5a60"
  UUID_V4 = /\A\h{8}-\h{4}-4\h{3}-[89ab]\h{3}-\h{12}\z/

  def key_object(**extra)
    { "id" => KEY_ID, "name" => "Kiosk 0412", "prefix" => "dn_live_", "scope" => "decide", "last4" => "9f3a",
      "device_id" => "kiosk-0412", "labels" => { "store" => "118", "fw" => "2.4" },
      "limits" => { "requests_per_second" => 5, "tokens_per_second" => 20_000 },
      "daily_spend_cap" => { "usd" => 2.0 }, "spent_today" => { "usd" => 0.0 },
      "expires_at" => "2027-10-13T00:00:00Z", "may_search_collections" => false, "status" => "active",
      "created_by_key" => { "id" => "key_1f0e2d3c4b5a69788796a5b4c3d2e1f0" }, "created_at" => "2026-10-20T09:12:04Z",
      "last_used_at" => nil, "revoked_at" => nil }.merge(extra)
  end

  def created
    { "key" => key_object, "secret" => "dn_live_#{'0' * 64}" }
  end

  def error(status, error_type, message, headers = {})
    FakeHTTP.json(status, { "detail" => { "error_type" => error_type, "message" => message } }, headers)
  end

  def path(call)
    URI(call.url).path
  end

  def raw_path(call)
    URI(call.url).request_uri.split("?").first
  end

  def query(call)
    URI.decode_www_form(URI(call.url).query.to_s).each_with_object({}) { |(k, v), h| (h[k] ||= []) << v }
  end

  def keys(http)
    http.calls.map { |c| c.headers["Idempotency-Key"] }
  end

  def assert_usage_error(message, &block)
    e = assert_raises(DecisionNode::BadRequestError, &block)
    assert_equal ["api_usage_error", message], [e.error_type, e.message]
    assert_nil e.status
  end

  # ---- create

  def test_create_sends_only_the_fields_given
    http = FakeHTTP.new(FakeHTTP.json(201, created))
    got = client(http).keys.create("Kiosk 0412", device_id: "kiosk-0412", labels: { "store" => "118" })
    sent = http.calls.first
    assert_equal ["POST", "/v1/keys"], [sent.method, path(sent)]
    assert_equal({ "name" => "Kiosk 0412", "device_id" => "kiosk-0412", "labels" => { "store" => "118" } }, sent.json)
    assert_equal created, got
  end

  def test_create_sends_every_field
    http = FakeHTTP.new(FakeHTTP.json(201, created))
    client(http).keys.create("Kiosk 0412", device_id: "kiosk-0412", labels: { "store" => "118", "fw" => "2.4" },
                                           limits: { "requests_per_second" => 5, "tokens_per_second" => 20_000 },
                                           daily_spend_cap: { "usd" => 2.0 }, expires_at: "2027-10-13T00:00:00Z",
                                           may_search_collections: false)
    assert_equal({ "name" => "Kiosk 0412", "device_id" => "kiosk-0412", "labels" => { "store" => "118", "fw" => "2.4" },
                   "limits" => { "requests_per_second" => 5, "tokens_per_second" => 20_000 },
                   "daily_spend_cap" => { "usd" => 2.0 }, "expires_at" => "2027-10-13T00:00:00Z",
                   "may_search_collections" => false }, http.calls.first.json)
  end

  def test_create_carries_a_new_key_kept_across_retries
    http = FakeHTTP.new(error(500, "api_error", "boom"), DecisionNode::ConnectionError.new("dropped"),
                        FakeHTTP.json(201, created))
    client(http, max_retries: 3).keys.create("Kiosk 0412")
    assert_equal 3, http.calls.size
    assert_equal 1, keys(http).uniq.size
    assert_match UUID_V4, keys(http).first
  end

  def test_each_create_gets_a_new_key
    http = FakeHTTP.new(FakeHTTP.json(201, created))
    dn = client(http)
    dn.keys.create("a")
    dn.keys.create("b")
    assert_equal 2, keys(http).uniq.size
  end

  def test_create_sends_the_callers_idempotency_key
    http = FakeHTTP.new(error(529, "overloaded_error", "busy", { "retry-after" => "1" }), FakeHTTP.json(201, created))
    client(http).keys.create("Kiosk 0412", idempotency_key: "enroll-kiosk-0412")
    assert_equal %w[enroll-kiosk-0412 enroll-kiosk-0412], keys(http)
  end

  def test_a_malformed_idempotency_key_is_refused_before_sending
    ["", "x" * 256, "café", "tab\there"].each do |bad|
      http = FakeHTTP.new(FakeHTTP.json(201, created))
      assert_usage_error("Idempotency-Key must be sent once, as 1 to 255 printable ASCII characters.") do
        client(http).keys.create("Kiosk 0412", idempotency_key: bad)
      end
      assert_empty http.calls
    end
  end

  def test_create_in_progress_is_retried_after_its_retry_after
    busy = error(409, "idempotency_in_progress",
                 "A request with this Idempotency-Key is still running. Try again shortly.", { "retry-after" => "1" })
    http = FakeHTTP.new(busy, FakeHTTP.json(201, created))
    dn = client(http)
    assert_equal created, dn.keys.create("Kiosk 0412")
    assert_equal 2, http.calls.size
    assert_equal 1, keys(http).uniq.size
    assert_equal [1.0], dn.sleeps
  end

  def test_a_create_409_is_raised_and_never_retried
    %w[idempotency_key_reused key_not_replayable].each do |error_type|
      http = FakeHTTP.new(error(409, error_type, "no"), FakeHTTP.json(201, created))
      dn = client(http)
      e = assert_raises(DecisionNode::DecisionNodeError) { dn.keys.create("Kiosk 0412") }
      assert_equal DecisionNode::DecisionNodeError, e.class
      assert_equal [409, error_type], [e.status, e.error_type]
      assert_equal 1, http.calls.size
      assert_empty dn.sleeps
    end
  end

  # ---- list, get, update, revoke

  def test_list_sends_its_filters
    http = FakeHTTP.new(FakeHTTP.json(200, { "items" => [key_object], "next_cursor" => nil }))
    page = client(http).keys.list(labels: { "store" => "118", "fw" => "2.4" }, device_id: "kiosk 0412", status: "all",
                                  limit: 50, cursor: "c1")
    sent = http.calls.first
    assert_equal ["GET", "/v1/keys"], [sent.method, path(sent)]
    assert_equal({ "label" => %w[fw:2.4 store:118], "device_id" => ["kiosk 0412"], "status" => ["all"],
                   "limit" => ["50"], "cursor" => ["c1"] }, query(sent))
    assert_equal({ "items" => [key_object], "next_cursor" => nil }, page)
  end

  def test_list_without_filters_sends_no_query
    http = FakeHTTP.new(FakeHTTP.json(200, { "items" => [], "next_cursor" => nil }))
    client(http).keys.list
    assert_nil URI(http.calls.first.url).query
  end

  def test_list_checks
    [
      [{ limit: 0 }, "limit is a whole number from 1 to 200."],
      [{ limit: 201 }, "limit is a whole number from 1 to 200."],
      [{ limit: true }, "limit is a whole number from 1 to 200."],
      [{ status: "gone" }, "status is active, expired, revoked or all."],
      [{ labels: { "Store" => "118" } }, "A label filter is name:value, as labels are written."],
      [{ labels: { "store" => "" } }, "A label filter is name:value, as labels are written."],
      [{ labels: { "store" => "a\nb" } }, "A label filter is name:value, as labels are written."],
      [{ device_id: " kiosk" }, "device_id is 1 to 128 printable ASCII characters, not starting with a space."],
      [{ device_id: "x" * 129 }, "device_id is 1 to 128 printable ASCII characters, not starting with a space."]
    ].each do |kwargs, message|
      http = FakeHTTP.new(FakeHTTP.json(200, { "items" => [], "next_cursor" => nil }))
      assert_usage_error(message) { client(http).keys.list(**kwargs) }
      assert_empty http.calls, kwargs.inspect
    end
  end

  def test_all_follows_the_cursor_through_short_pages
    second = key_object("id" => "key_#{'1' * 32}")
    http = FakeHTTP.new(FakeHTTP.json(200, { "items" => [key_object], "next_cursor" => "c1" }),
                        FakeHTTP.json(200, { "items" => [], "next_cursor" => "c2" }),
                        FakeHTTP.json(200, { "items" => [second], "next_cursor" => nil }))
    assert_equal [key_object, second], client(http).keys.all(labels: { "store" => "118" }, limit: 2)
    assert_equal [nil, ["c1"], ["c2"]], http.calls.map { |c| query(c)["cursor"] }
    http.calls.each { |c| assert_equal [["2"], ["store:118"]], query(c).values_at("limit", "label") }
  end

  def test_update_and_revoke_escape_the_id
    http = FakeHTTP.new(FakeHTTP.json(200, key_object))
    dn = client(http)
    dn.keys.update(KEY_ID, name: "x")
    dn.keys.revoke("key/../x")
    assert_equal [["PATCH", "/v1/keys/#{KEY_ID}"], ["DELETE", "/v1/keys/key%2F..%2Fx"]],
                 http.calls.map { |c| [c.method, raw_path(c)] }
    assert_raises(ArgumentError) { dn.keys.revoke("") }
    assert_raises(ArgumentError) { dn.keys.revoke(nil) }
  end

  def test_update_sends_only_the_fields_given_and_nil_clears
    http = FakeHTTP.new(FakeHTTP.json(200, key_object))
    got = client(http).keys.update(KEY_ID, name: "Kiosk 12", labels: { "store" => "120" }, daily_spend_cap: nil)
    sent = http.calls.first
    assert_equal ["PATCH", "/v1/keys/#{KEY_ID}"], [sent.method, path(sent)]
    assert_equal({ "name" => "Kiosk 12", "labels" => { "store" => "120" }, "daily_spend_cap" => nil }, sent.json)
    assert_nil sent.headers["Idempotency-Key"]
    assert_equal key_object, got
  end

  # The one 422 entry a local check raises, with nothing sent.
  def local_entry(&block)
    http = FakeHTTP.new(FakeHTTP.json(201, created))
    e = assert_raises(DecisionNode::ValidationError) { block.call(client(http).keys) }
    assert_empty http.calls
    assert_nil e.status
    assert_equal 1, e.entries.size
    e.entries.first
  end

  def test_create_checks
    device_rule = "device_id is 1 to 128 printable ASCII characters, not starting with a space."
    cap_rule = "daily_spend_cap.usd is from 0.01 to 1000, in cents, or null."
    [
      [["   "], %w[body name], "Give the key a name.", "   "],
      [["x" * 49], %w[body name], "Key names are at most 48 characters.", "x" * 49],
      [["k", { device_id: " kiosk" }], %w[body device_id], device_rule, " kiosk"],
      [["k", { labels: ["a"] }], %w[body labels], "labels is an object of names to values.", nil],
      [["k", { labels: (0..16).to_h { |i| [i.to_s, "v"] } }], %w[body labels], "A key has at most 16 labels.", nil],
      [["k", { labels: { "Store" => "1" } }], %w[body labels], "A label's name is 1 to 32 of a-z, 0-9, _ . and -.", nil],
      [["k", { labels: { "store" => "" } }], %w[body labels store], "A label's value is 1 to 64 characters of text.", nil],
      [["k", { limits: 5 }], %w[body limits], "limits is an object, or null.", 5],
      [["k", { daily_spend_cap: { "usd" => 0.005 } }], %w[body daily_spend_cap], cap_rule, nil],
      [["k", { daily_spend_cap: { "usd" => 1000.01 } }], %w[body daily_spend_cap], cap_rule, nil]
    ].each do |(name, kwargs), loc, msg, input|
      entry = local_entry { |keys| keys.create(name, **(kwargs || {})) }
      assert_equal ["value_error", loc, msg, input], entry.values_at("type", "loc", "msg", "input"), msg
    end
  end

  def test_create_checks_the_body_before_the_idempotency_key
    entry = local_entry { |keys| keys.create("", idempotency_key: "") }
    assert_equal "Give the key a name.", entry["msg"]
  end

  def test_a_whole_cent_cap_passes
    http = FakeHTTP.new(FakeHTTP.json(201, created))
    client(http).keys.create("k", daily_spend_cap: { "usd" => 1000 })
    assert_equal({ "usd" => 1000 }, http.calls.first.json["daily_spend_cap"])
  end

  def test_update_checks_what_it_sends_and_nil_clears_unchecked
    entry = local_entry { |keys| keys.update(KEY_ID, name: "x" * 49) }
    assert_equal "Key names are at most 48 characters.", entry["msg"]
    http = FakeHTTP.new(FakeHTTP.json(200, key_object))
    client(http).keys.update(KEY_ID, labels: nil, limits: nil, daily_spend_cap: nil)
    assert_equal({ "labels" => nil, "limits" => nil, "daily_spend_cap" => nil }, http.calls.first.json)
  end

  def test_revoke_by_labels_checks
    [
      [[{}], %w[body labels], "A bulk revoke names at least one label: every key it revokes has them all."],
      [[{ "store" => "1" }, ["d"] * 1001], %w[body device_ids], "device_ids is a list of at most 1,000 device ids."],
      [[{ "store" => "1" }, ["ok", " bad"]], %w[body device_id],
       "device_id is 1 to 128 printable ASCII characters, not starting with a space."]
    ].each do |(labels, devices), loc, msg|
      entry = local_entry { |keys| devices ? keys.revoke_by_labels(labels, device_ids: devices) : keys.revoke_by_labels(labels) }
      assert_equal [loc, msg], entry.values_at("loc", "msg"), msg
    end
  end

  def test_update_with_nothing_to_change_is_refused_before_sending
    http = FakeHTTP.new(FakeHTTP.json(200, key_object))
    assert_usage_error("Nothing to change.") { client(http).keys.update(KEY_ID) }
    assert_empty http.calls
  end

  def test_revoke_by_labels
    http = FakeHTTP.new(FakeHTTP.json(200, { "would_revoke" => 37, "more" => false }))
    got = client(http).keys.revoke_by_labels({ "store" => "118" }, device_ids: %w[a b], dry_run: true)
    sent = http.calls.first
    assert_equal ["POST", "/v1/keys/revoke"], [sent.method, path(sent)]
    assert_equal({ "labels" => { "store" => "118" }, "device_ids" => %w[a b], "dry_run" => true }, sent.json)
    assert_equal({ "would_revoke" => 37, "more" => false }, got)

    http = FakeHTTP.new(FakeHTTP.json(200, { "revoked" => 2, "more" => false }))
    client(http).keys.revoke_by_labels({ "store" => "118" })
    assert_equal({ "labels" => { "store" => "118" } }, http.calls.first.json)
  end

  def test_the_other_calls_carry_no_key_and_retry_as_usual
    {
      list: [], update: [KEY_ID, { name: "x" }], revoke: [KEY_ID], revoke_by_labels: [{ "store" => "118" }]
    }.each do |name, args|
      http = FakeHTTP.new(error(500, "api_error", "boom"), FakeHTTP.json(200, key_object))
      api = client(http).keys
      kwargs = args.last.is_a?(Hash) && name == :update ? args.last : nil
      positional = kwargs ? args[0...-1] : args
      kwargs ? api.public_send(name, *positional, **kwargs) : api.public_send(name, *positional)
      assert_equal 2, http.calls.size, name.to_s
      assert_equal [nil, nil], keys(http), name.to_s
    end
  end

  def test_errors_by_status
    [
      [403, "key_scope_denied", DecisionNode::PermissionDeniedError],
      [404, "not_found_error", DecisionNode::NotFoundError],
      [409, "already_revoked", DecisionNode::DecisionNodeError],
      [409, "key_expired", DecisionNode::DecisionNodeError]
    ].each do |status, error_type, klass|
      http = FakeHTTP.new(error(status, error_type, "no"))
      e = assert_raises(DecisionNode::DecisionNodeError) { client(http).keys.revoke(KEY_ID) }
      assert_equal klass, e.class
      assert_equal [status, error_type], [e.status, e.error_type]
    end
  end

  # ---- usage

  def test_usage_key_escapes_the_id_and_sends_what_is_given
    http = FakeHTTP.new(FakeHTTP.json(200, { "key" => { "id" => KEY_ID } }))
    client(http).usage.key("key/x", start: "2026-10-01T00:00:00Z", granularity: "day")
    sent = http.calls.first
    assert_equal "/v1/keys/key%2Fx/usage", raw_path(sent)
    assert_equal({ "start" => ["2026-10-01T00:00:00Z"], "granularity" => ["day"] }, query(sent))
  end

  def test_usage_all_follows_the_cursor
    http = FakeHTTP.new(FakeHTTP.json(200, { "items" => [{ "key" => { "id" => "a" } }], "next_cursor" => "c1" }),
                        FakeHTTP.json(200, { "items" => [{ "key" => { "id" => "b" } }], "next_cursor" => nil }))
    items = client(http).usage.all(start: "2026-10-01T00:00:00Z", end: "2026-10-14T00:00:00Z", include_empty: true)
    assert_equal [{ "key" => { "id" => "a" } }, { "key" => { "id" => "b" } }], items
    assert_equal [nil, ["c1"]], http.calls.map { |c| query(c)["cursor"] }
    assert_equal ["true"], query(http.calls.first)["include_empty"]
  end

  # ---- the spend cap

  CAP_REACHED = {
    "detail" => {
      "error_type" => "key_spend_cap_reached",
      "message" => "This key's daily spend cap of USD 2.00 is reached. It resets at 00:00 UTC.",
      "details" => { "resets_at" => "2026-10-21T00:00:00Z", "cap" => { "usd" => 2.0 }, "spent" => { "usd" => 2.01 } }
    }
  }.freeze

  def test_the_spend_cap_429_is_raised_and_never_retried
    http = FakeHTTP.new(FakeHTTP.json(429, CAP_REACHED, { "retry-after" => "3600" }), FakeHTTP.json(200, truth_body))
    dn = client(http)
    e = assert_raises(DecisionNode::RateLimitError) do
      dn.decide(state: "s", questions: { "q" => DecisionNode.truth("q?") })
    end
    assert_equal [429, "key_spend_cap_reached"], [e.status, e.error_type]
    assert_equal CAP_REACHED["detail"]["details"], e.details
    assert_equal 1, http.calls.size
    assert_empty dn.sleeps
  end

  def test_a_rate_429_is_still_retried
    rate = error(429, "rate_limit_error", "Rate limit reached. Retry after 1 s.", { "retry-after" => "1" })
    http = FakeHTTP.new(rate, FakeHTTP.json(200, truth_body))
    dn = client(http)
    dn.decide(state: "s", questions: { "q" => DecisionNode.truth("q?") })
    assert_equal 2, http.calls.size
    assert_equal [1.0], dn.sleeps
  end
end
