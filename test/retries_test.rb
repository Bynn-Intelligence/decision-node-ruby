# frozen_string_literal: true

require "test_helper"

class RetriesTest < Minitest::Test
  include ClientHelpers

  Q = { "q" => DecisionNode.truth("?") }.freeze

  def error(status, detail, headers = {})
    FakeHTTP.json(status, { "detail" => detail }, headers)
  end

  def test_retries_on_retryable_statuses_then_succeeds
    [408, 429, 500, 502, 503, 504, 529, 599].each do |status|
      http = FakeHTTP.new(error(status, "x"), FakeHTTP.json(200, truth_body))
      d = client(http).decide(questions: Q)
      assert_equal 2, http.calls.size, "status #{status}"
      assert_equal 0.5, d["q"].truth
    end
  end

  def test_gives_up_after_max_retries
    http = FakeHTTP.new(error(500, { "error_type" => "api_error", "message" => "Internal server error." }))
    dn = client(http)
    err = assert_raises(DecisionNode::ServerError) { dn.decide(questions: Q) }
    assert_equal 3, http.calls.size
    assert_equal "Internal server error.", err.message
    assert_equal 2, dn.sleeps.size
  end

  def test_never_retries_client_errors
    [400, 401, 402, 403, 404, 422].each do |status|
      http = FakeHTTP.new(error(status, "x"))
      assert_raises(DecisionNode::DecisionNodeError) { client(http).decide(questions: Q) }
      assert_equal 1, http.calls.size, "status #{status}"
    end
  end

  def test_retry_after_ms_wins_over_retry_after
    http = FakeHTTP.new(error(529, "x", "retry-after-ms" => "200", "retry-after" => "3"), FakeHTTP.json(200, truth_body))
    dn = client(http)
    dn.decide(questions: Q)
    assert_equal [0.2], dn.sleeps
  end

  def test_retry_after_seconds
    http = FakeHTTP.new(error(429, "x", "retry-after" => "1"), FakeHTTP.json(200, truth_body))
    dn = client(http)
    dn.decide(questions: Q)
    assert_equal [1.0], dn.sleeps
  end

  def test_retry_after_http_date
    date = (Time.now + 3).httpdate
    http = FakeHTTP.new(error(503, "x", "retry-after" => date), FakeHTTP.json(200, truth_body))
    dn = client(http)
    dn.decide(questions: Q)
    assert_equal 1, dn.sleeps.size
    assert_operator dn.sleeps.first, :>, 1.0
    assert_operator dn.sleeps.first, :<=, 3.0
  end

  def test_retry_after_date_in_the_past_is_no_wait
    http = FakeHTTP.new(error(503, "x", "retry-after" => (Time.now - 30).httpdate), FakeHTTP.json(200, truth_body))
    dn = client(http)
    dn.decide(questions: Q)
    assert_equal [0.0], dn.sleeps
  end

  def test_server_waits_are_capped_at_60_seconds
    [{ "retry-after-ms" => "600000" }, { "retry-after" => "3600" },
     { "retry-after" => (Time.now + 3600).httpdate }].each do |headers|
      http = FakeHTTP.new(error(529, "x", headers), FakeHTTP.json(200, truth_body))
      dn = client(http)
      dn.decide(questions: Q)
      assert_equal [60.0], dn.sleeps, headers.inspect
    end
  end

  def test_backoff_is_exponential_with_jitter_and_capped
    http = FakeHTTP.new(error(500, "x"))
    dn = client(http, max_retries: 6)
    assert_raises(DecisionNode::ServerError) { dn.decide(questions: Q) }
    dn.sleeps.each_with_index do |s, i|
      base = [8.0, 0.5 * (2**i)].min
      assert_operator s, :>=, base * 0.75
      assert_operator s, :<=, base
    end
  end

  def test_timeouts_and_connection_errors_are_retried
    http = FakeHTTP.new(DecisionNode::TimeoutError.new("slow"), DecisionNode::ConnectionError.new("reset"),
                        FakeHTTP.json(200, truth_body))
    client(http).decide(questions: Q)
    assert_equal 3, http.calls.size
  end

  def test_timeout_raised_after_retries
    http = FakeHTTP.new(DecisionNode::TimeoutError.new("slow"))
    assert_raises(DecisionNode::TimeoutError) { client(http, max_retries: 1).decide(questions: Q) }
    assert_equal 2, http.calls.size
  end

  def test_timeout_is_passed_per_attempt
    http = FakeHTTP.new(FakeHTTP.json(200, truth_body))
    client(http, timeout: 0.3).decide(questions: Q)
    assert_in_delta 0.3, http.calls.first.timeout
  end
end
