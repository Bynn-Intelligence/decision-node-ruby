# frozen_string_literal: true

require "test_helper"

# Collections of faces: each call's request, the Idempotency-Key and retries
# of create and enroll, the local checks, and the errors as the API sends them.
class CollectionsTest < Minitest::Test
  include ClientHelpers

  COL = "col_3f6c1a9e0b2d4c7f8a1e5d9b2c4f6a80"
  ITEM = "itm_9a0b1c2d3e4f5a6b7c8d9e0f1a2b3c4d"
  URL_IMAGE = DecisionNode::Image.new("badge", url: "https://files.example.com/badges/emp-1042.jpg")
  # A 1x1 PNG.
  PNG = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==".unpack1("m")

  def collection(**extra)
    { "id" => COL, "type" => "face", "name" => "Staff", "public" => false, "items" => 0, "deletion" => nil }.merge(extra)
  end

  def item
    { "id" => ITEM, "collection" => COL, "reference" => "emp-1042", "label" => "Reception", "faces_found" => 1,
      "box" => { "x1" => 1, "y1" => 2, "x2" => 3, "y2" => 4 }, "usage" => { "enrollments" => 1 } }
  end

  def error(status, error_type, message)
    FakeHTTP.json(status, { "detail" => { "error_type" => error_type, "message" => message } })
  end

  def path(call)
    URI(call.url).request_uri
  end

  # ---- the requests

  def test_create_sends_type_and_name_and_returns_the_object_as_sent
    http = FakeHTTP.new(FakeHTTP.json(201, collection))
    got = client(http).collections.create(name: "Staff")
    assert_equal ["POST", "/v1/collections", { "type" => "face", "name" => "Staff" }],
                 [http.calls.first.method, path(http.calls.first), http.calls.first.json]
    assert_equal collection, got
  end

  def test_list_returns_the_collections_in_order
    list = [collection, { "id" => "celebrities", "type" => "face", "name" => "Celebrities", "public" => true }]
    http = FakeHTTP.new(FakeHTTP.json(200, { "collections" => list }))
    assert_equal list, client(http).collections.list
    assert_equal ["GET", "/v1/collections"], [http.calls.first.method, path(http.calls.first)]
  end

  def test_get_and_delete_put_the_id_in_the_path_as_given
    http = FakeHTTP.new(FakeHTTP.json(200, collection), FakeHTTP.json(200, { "id" => COL, "deleted" => true }))
    dn = client(http)
    assert_equal collection, dn.collections.get(COL)
    assert_equal({ "id" => COL, "deleted" => true }, dn.collections.delete(COL))
    assert_equal [["GET", "/v1/collections/#{COL}"], ["DELETE", "/v1/collections/#{COL}"]],
                 http.calls.map { |c| [c.method, path(c)] }
    http = FakeHTTP.new(FakeHTTP.json(200, collection))
    client(http).collections.get("celebrities")
    assert_equal "/v1/collections/celebrities", path(http.calls.first)
    assert_raises(ArgumentError) { client(FakeHTTP.new).collections.get("") }
  end

  def test_enroll_sends_the_image_as_a_decision_does_and_the_label_only_when_given
    http = FakeHTTP.new(FakeHTTP.json(201, item))
    assert_equal item, client(http).collections.enroll(COL, image: URL_IMAGE, reference: "emp-1042", label: "Reception")
    sent = http.calls.first
    assert_equal ["POST", "/v1/collections/#{COL}/items"], [sent.method, path(sent)]
    assert_equal({ "image" => { "id" => "badge", "url" => "https://files.example.com/badges/emp-1042.jpg" },
                   "reference" => "emp-1042", "label" => "Reception" }, sent.json)

    http = FakeHTTP.new(FakeHTTP.json(201, item))
    client(http).collections.enroll(COL, image: DecisionNode::Image.new("badge", data: PNG), reference: "emp-1042")
    body = http.calls.first.json
    assert_equal %w[image reference], body.keys
    assert_equal ["badge", "image/png", [PNG].pack("m0")], body["image"].values_at("id", "media_type", "data")
  end

  def test_list_items_sends_offset_and_limit_only_when_given
    page = { "items" => [], "offset" => 20, "limit" => 50, "total" => 0, "next_offset" => nil }
    http = FakeHTTP.new(FakeHTTP.json(200, page))
    dn = client(http)
    assert_equal page, dn.collections.list_items(COL, offset: 20, limit: 50)
    dn.collections.list_items(COL)
    assert_equal ["/v1/collections/#{COL}/items?offset=20&limit=50", "/v1/collections/#{COL}/items"],
                 http.calls.map { |c| path(c) }
  end

  def test_delete_item
    http = FakeHTTP.new(FakeHTTP.json(200, { "id" => ITEM, "deleted" => true }))
    client(http).collections.delete_item(COL, ITEM)
    assert_equal ["DELETE", "/v1/collections/#{COL}/items/#{ITEM}"], [http.calls.first.method, path(http.calls.first)]
  end

  # ---- retries

  UUID_V4 = /\A\h{8}-\h{4}-4\h{3}-[89ab]\h{3}-\h{12}\z/

  def keys(http)
    http.calls.map { |c| c.headers["Idempotency-Key"] }
  end

  def test_create_and_enroll_retry_like_any_call_with_one_key_per_call
    [529, 429, 500, 503].each do |status|
      http = FakeHTTP.new(error(status, "x", "busy"), FakeHTTP.json(201, collection))
      assert_equal collection, client(http).collections.create(name: "Staff")
      assert_equal 2, http.calls.size, "create on #{status}"
      assert_match UUID_V4, keys(http).first
      assert_equal 1, keys(http).uniq.size, "create keeps its key across attempts"

      http = FakeHTTP.new(error(status, "x", "busy"), FakeHTTP.json(201, item))
      assert_equal item, client(http).collections.enroll(COL, image: URL_IMAGE, reference: "emp-1042")
      assert_equal 2, http.calls.size, "enroll on #{status}"
      assert_equal 1, keys(http).uniq.size, "enroll keeps its key across attempts"
    end
    http = FakeHTTP.new(DecisionNode::TimeoutError.new("slow"), FakeHTTP.json(201, item))
    assert_equal item, client(http).collections.enroll(COL, image: URL_IMAGE, reference: "emp-1042")
    assert_equal 2, http.calls.size
    assert_equal 1, keys(http).uniq.size
  end

  def test_a_new_key_for_each_call
    http = FakeHTTP.new(FakeHTTP.json(201, collection), FakeHTTP.json(201, collection))
    dn = client(http)
    2.times { dn.collections.create(name: "Staff") }
    assert_equal 2, keys(http).uniq.size
    keys(http).each { |k| assert_match UUID_V4, k }
  end

  def test_in_progress_is_retried_after_its_retry_after
    busy = FakeHTTP.json(409, { "detail" => { "error_type" => "idempotency_in_progress",
                                              "message" => "A request with this Idempotency-Key is still running." } },
                         { "retry-after" => "1" })
    http = FakeHTTP.new(busy, FakeHTTP.json(201, item, { "x-decisionnode-idempotent-replay" => "true" }))
    dn = client(http)
    assert_equal item, dn.collections.enroll(COL, image: URL_IMAGE, reference: "emp-1042")
    assert_equal 2, http.calls.size
    assert_equal [1.0], dn.sleeps
    assert_equal 1, keys(http).uniq.size
  end

  def test_a_reused_key_is_raised_and_never_retried
    reused = error(409, "idempotency_key_reused", "This Idempotency-Key was already used with a different request.")
    http = FakeHTTP.new(reused, FakeHTTP.json(201, collection))
    e = assert_raises(DecisionNode::DecisionNodeError) { client(http).collections.create(name: "Staff") }
    assert_equal DecisionNode::DecisionNodeError, e.class
    assert_equal [409, "idempotency_key_reused"], [e.status, e.error_type]
    assert_equal 1, http.calls.size
  end

  def test_reads_and_deletes_carry_no_key
    http = FakeHTTP.new(FakeHTTP.json(200, { "collections" => [] }), FakeHTTP.json(200, collection),
                        FakeHTTP.json(200, { "items" => [] }), FakeHTTP.json(200, { "id" => COL, "deleted" => true }),
                        FakeHTTP.json(200, { "id" => ITEM, "deleted" => true }))
    dn = client(http)
    dn.collections.list
    dn.collections.get(COL)
    dn.collections.list_items(COL)
    dn.collections.delete(COL)
    dn.collections.delete_item(COL, ITEM)
    assert_equal [nil] * 5, keys(http)
  end

  def test_reads_and_deletes_retry_as_usual
    http = FakeHTTP.new(error(500, "server_error", "oops"), FakeHTTP.json(200, collection))
    assert_equal collection, client(http).collections.get(COL)
    assert_equal 2, http.calls.size
  end

  # ---- local checks

  def assert_entries(expected, &block)
    error = assert_raises(DecisionNode::ValidationError, &block)
    assert_nil error.status
    assert_nil error.request_id
    assert_equal expected, error.entries
  end

  def test_create_checks_type_and_name
    http = FakeHTTP.new(FakeHTTP.json(201, collection))
    dn = client(http)
    assert_entries([{ "type" => "literal_error", "loc" => %w[body type], "msg" => "Input should be 'face'", "input" => "car",
                      "ctx" => { "expected" => "'face'" } }]) { dn.collections.create(name: "Staff", type: "car") }
    assert_entries([{ "type" => "string_too_short", "loc" => %w[body name], "msg" => "String should have at least 1 character",
                      "input" => "", "ctx" => { "min_length" => 1 } }]) { dn.collections.create(name: "") }
    assert_entries([{ "type" => "string_too_long", "loc" => %w[body name], "msg" => "String should have at most 80 characters",
                      "input" => "#{"n" * 64}...", "ctx" => { "max_length" => 80 } }]) { dn.collections.create(name: "n" * 81) }
    # A string input is echoed cut to 64 characters, counted as characters; an object never.
    assert_entries([{ "type" => "string_too_long", "loc" => %w[body name], "msg" => "String should have at most 80 characters",
                      "input" => "#{"\u{20000}" * 64}...", "ctx" => { "max_length" => 80 } }]) do
      dn.collections.create(name: "\u{20000}" * 81)
    end
    assert_entries([{ "type" => "string_type", "loc" => %w[body name], "msg" => "Input should be a valid string",
                      "input" => nil }]) { dn.collections.create(name: { "a" => 1 }) }
    assert_entries([{ "type" => "string_type", "loc" => %w[body name], "msg" => "Input should be a valid string",
                      "input" => 7 }]) { dn.collections.create(name: 7) }
    assert_entries([{ "type" => "literal_error", "loc" => %w[body type], "msg" => "Input should be 'face'",
                      "input" => "#{"t" * 64}...", "ctx" => { "expected" => "'face'" } }]) do
      dn.collections.create(name: "Staff", type: "t" * 70)
    end
    assert_equal collection, dn.collections.create(name: "n" * 80)
    assert_equal 1, http.calls.size # only the 80-character name was sent
  end

  def test_enroll_checks_reference_and_label
    http = FakeHTTP.new
    dn = client(http)
    pattern = "^[A-Za-z0-9_.:-]{1,64}$"
    assert_entries([{ "type" => "string_pattern_mismatch", "loc" => %w[body reference],
                      "msg" => "String should match pattern '#{pattern}'", "input" => "emp 1042",
                      "ctx" => { "pattern" => pattern } }]) { dn.collections.enroll(COL, image: URL_IMAGE, reference: "emp 1042") }
    assert_entries([{ "type" => "string_pattern_mismatch", "loc" => %w[body reference],
                      "msg" => "String should match pattern '#{pattern}'", "input" => "a\nb",
                      "ctx" => { "pattern" => pattern } }]) { dn.collections.enroll(COL, image: URL_IMAGE, reference: "a\nb") }
    # The length comes before the pattern: an empty reference is too short; a missing one is "missing".
    assert_entries([{ "type" => "string_too_short", "loc" => %w[body reference],
                      "msg" => "String should have at least 1 character", "input" => "",
                      "ctx" => { "min_length" => 1 } }]) { dn.collections.enroll(COL, image: URL_IMAGE, reference: "") }
    # A label, when given, may not be empty.
    assert_entries([{ "type" => "string_too_short", "loc" => %w[body label],
                      "msg" => "String should have at least 1 character", "input" => "",
                      "ctx" => { "min_length" => 1 } }]) do
      dn.collections.enroll(COL, image: URL_IMAGE, reference: "emp-1042", label: "")
    end
    # A missing image's input is nil.
    assert_entries([{ "type" => "missing", "loc" => %w[body image], "msg" => "Field required", "input" => nil }]) do
      dn.collections.enroll(COL, image: nil, reference: "emp-1042")
    end
    assert_entries([{ "type" => "missing", "loc" => %w[body reference], "msg" => "Field required", "input" => nil }]) do
      dn.collections.enroll(COL, image: URL_IMAGE, reference: nil)
    end
    assert_entries([{ "type" => "string_too_long", "loc" => %w[body reference], "msg" => "String should have at most 64 characters",
                      "input" => "#{"r" * 64}...", "ctx" => { "max_length" => 64 } }]) do
      dn.collections.enroll(COL, image: URL_IMAGE, reference: "r" * 65)
    end
    assert_entries([{ "type" => "string_too_long", "loc" => %w[body label], "msg" => "String should have at most 128 characters",
                      "input" => "#{"l" * 64}...", "ctx" => { "max_length" => 128 } }]) do
      dn.collections.enroll(COL, image: URL_IMAGE, reference: "emp-1042", label: "l" * 129)
    end
    # A URL's rules are checked before sending, as for a decision's image.
    assert_raises(DecisionNode::BadRequestError) do
      dn.collections.enroll(COL, image: DecisionNode::Image.new("x", url: "http://files.example.com/x.jpg"), reference: "r")
    end
    assert_empty http.calls
  end

  def test_any_other_fault_of_the_picture_is_left_to_the_server
    gif = DecisionNode::Image.new("badge", data: "GIF89a\x01\x00\x01\x00".b)
    unreadable = FakeHTTP.json(422, { "detail" => [{ "type" => "image_unreadable", "loc" => %w[body image],
                                                     "msg" => "The image could not be read: not a JPEG, PNG or WebP image.",
                                                     "input" => "badge" }] })
    http = FakeHTTP.new(unreadable)
    e = assert_raises(DecisionNode::ValidationError) { client(http).collections.enroll(COL, image: gif, reference: "emp-1042") }
    assert_equal [422, "image_unreadable"], [e.status, e.entries.first["type"]]
    assert_equal 1, http.calls.size
    assert_equal "badge", http.calls.first.json.dig("image", "id")
  end

  def test_list_items_checks_offset_and_limit
    dn = client(FakeHTTP.new)
    { { limit: 0 } => "limit must be an integer from 1 to 100, got 0",
      { limit: 101 } => "limit must be an integer from 1 to 100, got 101",
      { offset: -1 } => "offset must be an integer of 0 or more, got -1" }.each do |args, message|
      error = assert_raises(DecisionNode::BadRequestError) { dn.collections.list_items(COL, **args) }
      assert_equal "api_usage_error", error.error_type
      assert_includes error.message, message
    end
  end

  # ---- errors, read as sent

  def test_errors_by_status
    {
      error(404, "collection_not_found", "Collection not found.") => DecisionNode::NotFoundError,
      error(404, "item_not_found", "Item not found.") => DecisionNode::NotFoundError,
      error(403, "collection_read_only", "This collection is public and read-only.") => DecisionNode::PermissionDeniedError,
      error(403, "collection_not_enabled", "Collections are not enabled.") => DecisionNode::PermissionDeniedError,
      error(403, "collections_region_unavailable", "Not in this region.") => DecisionNode::PermissionDeniedError,
      error(400, "collection_type_mismatch", "Not a face collection.") => DecisionNode::BadRequestError,
      error(409, "items_limit_reached", "Limit reached.") => DecisionNode::DecisionNodeError,
      error(409, "collections_limit_reached", "Limit reached.") => DecisionNode::DecisionNodeError,
      error(422, "no_face", "No face was found in the image.") => DecisionNode::ValidationError
    }.each do |response, klass|
      http = FakeHTTP.new(response)
      e = assert_raises(DecisionNode::DecisionNodeError) do
        client(http, max_retries: 0).collections.enroll(COL, image: URL_IMAGE, reference: "emp-1042")
      end
      assert_equal klass, e.class
      assert_equal JSON.parse(response.body).dig("detail", "error_type"), e.error_type
      assert_equal JSON.parse(response.body).dig("detail", "message"), e.message
    end
  end
end
