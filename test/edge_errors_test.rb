# frozen_string_literal: true

require "test_helper"

# Error bodies that are not the API's JSON envelope (an edge's or a proxy's
# page, or no body), and image ids of at most 64 characters.
class EdgeErrorsTest < Minitest::Test
  include ClientHelpers

  Q = { "q" => DecisionNode.truth("?") }.freeze
  PAGE = { "content-type" => "text/html" }.freeze

  def page(status, html, headers = {})
    DecisionNode::HTTPResponse.new(status, PAGE.merge(headers), html)
  end

  def raise_for(response, **kw)
    http = FakeHTTP.new(response)
    err = assert_raises(DecisionNode::DecisionNodeError) { client(http, max_retries: 0, **kw).decide(questions: Q) }
    [err, http]
  end

  # ---- error bodies that are not JSON

  def test_a_413_page_without_a_request_id
    err, = raise_for(page(413, "<html><body><h1>413 Request Entity Too Large</h1></body></html>"))
    assert_instance_of DecisionNode::RequestTooLargeError, err
    assert_equal [413, nil, "HTTP 413 Content Too Large", nil, nil],
                 [err.status, err.error_type, err.message, err.request_id, err.reason]
    assert_nil err.body
  end

  def test_a_413_page_is_never_retried
    http = FakeHTTP.new(page(413, "<html>too large</html>"), FakeHTTP.json(200, truth_body))
    assert_raises(DecisionNode::RequestTooLargeError) { client(http).decide(questions: Q) }
    assert_equal 1, http.calls.size
  end

  def test_a_408_page_is_retried_then_raised_with_its_request_id
    http = FakeHTTP.new(page(408, "<html><body><h1>408 Request Time-out</h1></body></html>",
                             "x-request-id" => "req_edge_0408"))
    err = assert_raises(DecisionNode::DecisionNodeError) { client(http).decide(questions: Q) }
    assert_equal DecisionNode::DecisionNodeError, err.class
    assert_equal 3, http.calls.size
    assert_equal [408, nil, "HTTP 408 Request Timeout (request id req_edge_0408)", "req_edge_0408", nil],
                 [err.status, err.error_type, err.message, err.request_id, err.reason]
  end

  def test_a_408_page_then_a_decision
    http = FakeHTTP.new(page(408, "<html>timeout</html>"), FakeHTTP.json(200, truth_body))
    assert_equal 0.5, client(http).decide(questions: Q)["q"].truth
    assert_equal 2, http.calls.size
  end

  def test_the_class_follows_the_status_alone
    {
      400 => [DecisionNode::BadRequestError, "HTTP 400 Bad Request"],
      403 => [DecisionNode::PermissionDeniedError, "HTTP 403 Forbidden"],
      422 => [DecisionNode::ValidationError, "HTTP 422 Unprocessable Content"],
      429 => [DecisionNode::RateLimitError, "HTTP 429 Too Many Requests"],
      529 => [DecisionNode::OverloadedError, "HTTP 529 Overloaded"],
      503 => [DecisionNode::ServerError, "HTTP 503 Service Unavailable"]
    }.each do |status, (klass, message)|
      err, = raise_for(page(status, "<html>#{status}</html>", "x-decisionnode-error" => "edge"))
      assert_equal klass, err.class, status
      assert_equal message, err.message
      assert_nil err.error_type
      assert_equal "edge", err.reason
    end
  end

  def test_never_a_context_limit_or_refusal_without_the_envelope
    err, = raise_for(page(400, "max_tokens_exceeded"))
    refute_kind_of DecisionNode::ContextLimitError, err
    err, = raise_for(page(403, "refusal_error"))
    refute_kind_of DecisionNode::RefusalError, err
    err, = raise_for(page(422, "<html>422</html>"))
    assert_nil err.entries
  end

  def test_retry_after_is_read_from_the_headers
    err, = raise_for(page(429, "slow down", "retry-after" => "2"))
    assert_equal 2.0, err.retry_after
  end

  def test_an_empty_body
    err, = raise_for(page(502, ""))
    assert_equal [DecisionNode::ServerError, "HTTP 502 Bad Gateway"], [err.class, err.message]
  end

  def test_a_status_outside_the_table
    err, = raise_for(page(418, "teapot", "x-request-id" => "req_1"))
    assert_equal [DecisionNode::DecisionNodeError, "HTTP 418 (request id req_1)"], [err.class, err.message]
    err, = raise_for(page(507, ""))
    assert_equal [DecisionNode::ServerError, "HTTP 507"], [err.class, err.message]
  end

  def test_a_json_body_keeps_the_envelope_rules
    err, = raise_for(FakeHTTP.json(400, {}))
    assert_equal "", err.message
    err, = raise_for(FakeHTTP.json(400, { "detail" => { "error_type" => "api_usage_error" } }))
    assert_equal ["", "api_usage_error"], [err.message, err.error_type]
  end

  # ---- image ids of at most 64 characters

  URL = "https://files.example.com/a.jpg"

  def image(id)
    DecisionNode::Image.new(id, url: URL)
  end

  def test_an_id_of_64_characters_is_sent
    http = FakeHTTP.new(FakeHTTP.json(200, truth_body))
    client(http).decide(questions: Q, images: [image("a" * 64)])
    assert_equal "a" * 64, http.calls.first.json["images"].first["id"]
  end

  def test_64_characters_outside_the_basic_plane_are_sent
    id = "\u{20000}" * 64
    http = FakeHTTP.new(FakeHTTP.json(200, truth_body))
    client(http).decide(questions: Q, images: [{ "id" => id, "url" => URL }])
    assert_equal id, http.calls.first.json["images"].first["id"]
  end

  def test_an_id_of_65_characters_is_refused_before_sending
    http = FakeHTTP.new(FakeHTTP.json(200, truth_body))
    err = assert_raises(DecisionNode::BadRequestError) do
      client(http).decide(questions: Q, images: [image("a"), image("\u{20000}" * 65)])
    end
    assert_equal ["Image 1: its id is longer than 64 characters.", "api_usage_error", nil, nil],
                 [err.message, err.error_type, err.status, err.request_id]
    assert_empty http.calls
  end

  def test_a_long_id_that_is_also_a_duplicate_is_reported_as_too_long
    long = "b" * 65
    err = assert_raises(DecisionNode::BadRequestError) do
      client(FakeHTTP.new(FakeHTTP.json(200, truth_body))).check_request(
        "decide", questions: Q, images: [{ "id" => long, "url" => URL }, image(long)]
      )
    end
    assert_equal "Image 0: its id is longer than 64 characters.", err.message
  end

  def test_the_empty_id_check_comes_first
    err = assert_raises(DecisionNode::BadRequestError) do
      client(FakeHTTP.new(FakeHTTP.json(200, truth_body))).decide(questions: Q, images: [{ "id" => "", "url" => URL }])
    end
    assert_equal "Image 0 needs an id.", err.message
  end

  def test_batch_lines_and_decide_many_check_it_too
    http = FakeHTTP.new(FakeHTTP.json(200, truth_body))
    dn = client(http)
    requests = [{ questions: Q }, { questions: Q, images: [image("c" * 65)] }]
    assert_raises(DecisionNode::BadRequestError) { dn.decide_many(requests) }
    assert_raises(DecisionNode::BadRequestError) do
      dn.batches.create([{ custom_id: "r1", questions: Q, images: [image("c" * 65)] }])
    end
    assert_empty http.calls
  end
end
