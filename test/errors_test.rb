# frozen_string_literal: true

require "test_helper"

class ErrorsTest < Minitest::Test
  include ClientHelpers

  Q = { "q" => DecisionNode.truth("?") }.freeze

  def raise_for(status, body, headers = {})
    http = FakeHTTP.new(FakeHTTP.json(status, body, headers))
    assert_raises(DecisionNode::DecisionNodeError) { client(http, max_retries: 0).decide(questions: Q) }
  end

  def test_status_to_class
    {
      400 => DecisionNode::BadRequestError, 401 => DecisionNode::AuthenticationError,
      402 => DecisionNode::InsufficientCreditError, 403 => DecisionNode::PermissionDeniedError,
      404 => DecisionNode::NotFoundError, 422 => DecisionNode::ValidationError,
      429 => DecisionNode::RateLimitError, 529 => DecisionNode::OverloadedError,
      500 => DecisionNode::ServerError, 503 => DecisionNode::ServerError
    }.each do |status, cls|
      assert_instance_of cls, raise_for(status, { "detail" => "x" }), "status #{status}"
    end
  end

  def test_unmapped_statuses_and_redirects_give_the_base_class
    [301, 302, 307, 308, 405, 409, 418].each do |status|
      http = FakeHTTP.new(FakeHTTP.json(status, { "detail" => "x" }, "location" => "http://elsewhere.example/v1/decide"))
      err = assert_raises(DecisionNode::DecisionNodeError) { client(http).decide(questions: Q) }
      assert_instance_of DecisionNode::DecisionNodeError, err, "status #{status}"
      assert_equal status, err.status
      assert_equal 1, http.calls.size, "status #{status} must not be retried or followed"
    end
  end

  def test_only_2xx_is_success
    http = FakeHTTP.new(FakeHTTP.json(204, {}))
    assert_instance_of DecisionNode::Decision, client(http).decide(questions: Q)
    http = FakeHTTP.new(FakeHTTP.json(304, {}))
    assert_raises(DecisionNode::DecisionNodeError) { client(http).decide(questions: Q) }
  end

  def test_context_limit
    err = raise_for(400, { "detail" => { "error_type" => "max_tokens_exceeded" } })
    assert_instance_of DecisionNode::ContextLimitError, err
    assert_kind_of DecisionNode::BadRequestError, err
    assert_equal "", err.message
  end

  def test_fields_from_body_and_headers
    err = raise_for(400, { "detail" => "Unknown model: x" },
                    "x-request-id" => "req_e", "x-decisionnode-error" => "model 'x' is not known")
    assert_equal 400, err.status
    assert_equal "Unknown model: x", err.message
    assert_nil err.error_type
    assert_equal "req_e", err.request_id
    assert_equal "model 'x' is not known", err.reason
  end

  def test_refusal
    err = raise_for(403, { "detail" => { "error_type" => "refusal_error", "category" => "harm", "message" => "Refused." } },
                    "x-decisionnode-safety" => "harm=0.97;blocked, self_harm=0.01",
                    "x-decisionnode-refusal" => "harm")
    assert_instance_of DecisionNode::RefusalError, err
    assert_equal "harm", err.category
    assert_equal ["harm"], err.safety.flagged
  end

  def test_validation_entries
    entries = [{ "type" => "missing", "loc" => %w[body questions], "msg" => "Field required" }]
    err = raise_for(422, { "detail" => entries })
    assert_equal entries, err.entries
    assert_equal "", err.message
  end

  def test_retry_after_seconds
    err = raise_for(429, { "detail" => "x" }, "retry-after-ms" => "1500", "retry-after" => "9")
    assert_in_delta 1.5, err.retry_after
    err = raise_for(529, { "detail" => "x" }, "retry-after" => "2")
    assert_in_delta 2.0, err.retry_after
    assert_nil raise_for(529, { "detail" => "x" }).retry_after
    assert_in_delta 60.0, raise_for(429, { "detail" => "x" }, "retry-after" => "3600").retry_after
  end

  def test_message_is_the_server_message
    err = raise_for(400, { "detail" => { "error_type" => "invalid_request_error", "message" => "Bad." } },
                    "x-decisionnode-error" => "question 'q': too many levels")
    assert_equal "Bad.", err.message
    assert_equal "Bad.", err.to_s
    assert_equal "question 'q': too many levels", err.reason
  end

  def test_non_json_body
    http = FakeHTTP.new(DecisionNode::HTTPResponse.new(502, { "content-type" => "text/html" }, "<html>bad gateway</html>"))
    err = assert_raises(DecisionNode::ServerError) { client(http, max_retries: 0).decide(questions: Q) }
    assert_equal 502, err.status
    assert_equal "HTTP 502 Bad Gateway", err.message
    assert_nil err.body
  end

  def test_success_status_with_non_json_body
    http = FakeHTTP.new(DecisionNode::HTTPResponse.new(200, {}, "not json"))
    assert_raises(DecisionNode::ServerError) { client(http).decide(questions: Q) }
  end

  def test_full_message_is_readable
    err = raise_for(400, { "detail" => { "error_type" => "max_tokens_exceeded" } })
    text = err.full_message(highlight: false)
    assert_includes text, "max_tokens_exceeded"
    assert_includes text, "HTTP 400"
  end
end
