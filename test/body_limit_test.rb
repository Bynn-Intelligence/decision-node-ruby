# frozen_string_literal: true

require_relative "test_helper"
require_relative "uploads_test"

# The API's request body limit, 26,214,400 bytes (25 MiB): checked on the
# encoded body before anything is sent or uploaded, and the API's 413 mapped
# to RequestTooLargeError and never retried.
class BodyLimitTest < Minitest::Test
  include ClientHelpers

  LIMIT = 26_214_400
  MESSAGE = "The request body is over 26,214,400 bytes (25 MiB). Send large images as uploads " \
            "(POST /v1/uploads) and name them by upload_id."
  Q = { "q" => DecisionNode.truth("?") }.freeze

  # The bytes of a decide body around its state, as this client encodes it.
  def overhead
    JSON.generate({ "model" => DecisionNode::DEFAULT_MODEL, "state" => "", "questions" => Q }).bytesize
  end

  def ok
    FakeHTTP.json(200, truth_body)
  end

  def png(pad_to = nil)
    bytes = File.binread(File.join(UploadsTest::FIXTURES, "image.png"))
    pad_to ? bytes + ("\0".b * (pad_to - bytes.bytesize)) : bytes
  end

  def assert_too_large(error, size)
    assert_nil error.status
    assert_nil error.request_id
    assert_equal "request_too_large_error", error.error_type
    assert_equal MESSAGE, error.message
    assert_equal "the body is #{size} bytes; the limit is #{LIMIT}", error.reason
  end

  def test_a_body_of_exactly_the_limit_is_sent
    http = FakeHTTP.new(ok)
    client(http).decide(state: "a" * (LIMIT - overhead), questions: Q)
    assert_equal 1, http.calls.size
    assert_equal LIMIT, http.calls.first.body.bytesize
  end

  def test_one_byte_over_the_limit_is_refused_and_nothing_is_sent
    http = FakeHTTP.new(ok)
    error = assert_raises(DecisionNode::RequestTooLargeError) do
      client(http).decide(state: "a" * (LIMIT - overhead + 1), questions: Q)
    end
    assert_too_large(error, LIMIT + 1)
    assert_empty http.calls
  end

  def test_the_helpers_check_the_body
    http = FakeHTTP.new(ok)
    big = "a" * LIMIT
    assert_raises(DecisionNode::RequestTooLargeError) { client(http).check(state: big, instructions: "?") }
    assert_raises(DecisionNode::RequestTooLargeError) { client(http).gate(action: big) }
    assert_empty http.calls
  end

  def test_decide_many_raises_for_the_whole_call_before_anything_is_sent
    http = FakeHTTP.new(ok)
    requests = [{ state: "small", questions: Q }, { state: "a" * LIMIT, questions: Q }]
    assert_raises(DecisionNode::RequestTooLargeError) { client(http).decide_many(requests) }
    assert_empty http.calls
  end

  def test_check_request_raises_what_the_call_would
    http = FakeHTTP.new(ok)
    dn = client(http)
    assert_raises(DecisionNode::RequestTooLargeError) { dn.check_request("decide", state: "a" * LIMIT, questions: Q) }
    big = { custom_id: "big", state: "a" * LIMIT, questions: Q }
    assert_raises(DecisionNode::RequestTooLargeError) { dn.check_request("batches.create", requests: [big]) }
    assert_raises(DecisionNode::RequestTooLargeError) { dn.check_request("batches.add", requests: [big]) }
    assert_nil dn.check_request("decide", state: "a" * (LIMIT - overhead), questions: Q)
    assert_empty http.calls
  end

  # A batch line is measured as it is sent, custom_id included.
  def test_a_batch_line_counts_its_custom_id
    line_overhead = JSON.generate({ "custom_id" => "c", "model" => DecisionNode::DEFAULT_MODEL, "state" => "",
                                    "questions" => Q }).bytesize
    state = "a" * (LIMIT - line_overhead)
    http = FakeHTTP.new(FakeHTTP.json(201, { "id" => "batch_1", "state" => "draft", "counters" => {} }))
    client(http).batches.create([{ custom_id: "c", state: state, questions: Q }])
    assert_equal LIMIT + 1, http.calls.first.body.bytesize # the line and its newline

    http = FakeHTTP.new(FakeHTTP.json(201, { "id" => "batch_1", "state" => "draft", "counters" => {} }))
    error = assert_raises(DecisionNode::RequestTooLargeError) do
      client(http).batches.create([{ custom_id: "cc", state: state, questions: Q }])
    end
    assert_too_large(error, LIMIT + 1)
    assert_empty http.calls
  end

  # An image above the inline threshold counts as {"id", "upload_id"} with an
  # id of the API's length, and nothing is uploaded when the body is over.
  def test_an_image_to_upload_counts_by_its_upload_id
    image = -> { DecisionNode::Image.new("a", data: png(600_000)) }
    probe = UploadsTest::FakeAPI.new
    client(probe).decide(state: "", questions: Q, images: [image.call])
    base = probe.calls_to("POST", "/v1/decide").first.body.bytesize

    api = UploadsTest::FakeAPI.new
    client(api).decide(state: "a" * (LIMIT - base), questions: Q, images: [image.call])
    assert_equal LIMIT, api.calls_to("POST", "/v1/decide").first.body.bytesize

    api = UploadsTest::FakeAPI.new
    error = assert_raises(DecisionNode::RequestTooLargeError) do
      client(api).decide(state: "a" * (LIMIT - base + 1), questions: Q, images: [image.call])
    end
    assert_too_large(error, LIMIT + 1)
    assert_empty api.calls
  end

  def test_a_413_is_mapped_and_never_retried
    too_large = FakeHTTP.json(413, { "detail" => { "error_type" => "request_too_large_error", "message" => MESSAGE } },
                              { "retry-after-ms" => "20", "x-request-id" => "req_1" })
    http = FakeHTTP.new(too_large)
    error = assert_raises(DecisionNode::RequestTooLargeError) { client(http).decide(state: "s", questions: Q) }
    assert_equal [413, "request_too_large_error", MESSAGE, "req_1"], [error.status, error.error_type, error.message, error.request_id]
    assert_equal 1, http.calls.size
  end

  def test_a_413_on_the_presign_and_on_a_batch_add
    http = FakeHTTP.new(FakeHTTP.json(413, { "detail" => "too large" }))
    image = DecisionNode::Image.new("a", data: png)
    assert_raises(DecisionNode::RequestTooLargeError) { client(http).upload([image]) }
    assert_equal 1, http.calls.size

    http = FakeHTTP.new(FakeHTTP.json(413, { "detail" => "too large" }))
    assert_raises(DecisionNode::RequestTooLargeError) do
      client(http).batches.add("batch_1", [{ custom_id: "a", state: "s", questions: Q }])
    end
    assert_equal 1, http.calls.size
  end
end
