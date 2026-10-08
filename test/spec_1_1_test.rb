# frozen_string_literal: true

require_relative "test_helper"

# Number questions, local request checks, sessions and the Batch API.
class Spec11Test < Minitest::Test
  include ClientHelpers

  # ---- number

  def test_number_helper_and_answer
    answer = { "type" => "number", "number" => 3.5, "expected" => 3.52, "confidence" => 0.61,
               "probabilities" => { "3" => 0.2, "3.5" => 0.611, "4" => 0.18 } }
    http = FakeHTTP.new(FakeHTTP.json(200, { "answers" => { "number" => answer } }))
    result = client(http).number(state: "s", instructions: "Rating?", min: 0, max: 5, step: 0.5)
    assert_instance_of DecisionNode::NumberAnswer, result
    assert_equal [3.5, 3.52, 0.61], [result.number, result.expected, result.confidence]
    assert_equal({ "3" => 0.2, "3.5" => 0.611, "4" => 0.18 }, result.probabilities)
    assert_equal({ "number" => { "type" => "number", "instructions" => "Rating?", "min" => 0, "max" => 5, "step" => 0.5 } },
                 http.calls.first.json["questions"])
  end

  # ---- local checks

  def assert_refused_locally(klass, questions)
    http = FakeHTTP.new(FakeHTTP.json(200, truth_body))
    error = assert_raises(klass) { client(http).decide(state: "s", questions: questions) }
    assert_instance_of klass, error
    assert_nil error.status
    assert_empty http.calls
    error
  end

  def test_fixed_rules_are_checked_before_any_request
    assert_refused_locally(DecisionNode::BadRequestError, { "q" => DecisionNode.choice("?", []) })
    assert_refused_locally(DecisionNode::BadRequestError, { "q" => DecisionNode.choice("?", (0..255).map(&:to_s)) })
    assert_refused_locally(DecisionNode::BadRequestError, { "q" => DecisionNode.score("?", (0..10).map(&:to_s)) })
    assert_refused_locally(DecisionNode::ValidationError, { "q" => DecisionNode.score("?", []) })
    assert_refused_locally(DecisionNode::BadRequestError, { "q" => DecisionNode.truth })
    assert_refused_locally(DecisionNode::BadRequestError, { "q" => { "type" => "noul" } })
    assert_refused_locally(DecisionNode::BadRequestError, { "q" => DecisionNode.number(nil, min: 0, max: 10) })
    error = assert_refused_locally(DecisionNode::ValidationError, { "q" => DecisionNode.number("%", min: 0, max: 1000, step: 0.1) })
    assert_equal "too_long", error.entries.first["type"]
    assert_refused_locally(DecisionNode::ValidationError, { "q" => DecisionNode.number("n", min: 60, max: 50) })
    assert_refused_locally(DecisionNode::ValidationError, { "q" => DecisionNode.number("n", step: 0) })
    assert_refused_locally(DecisionNode::ValidationError, { "q" => DecisionNode.number("n", min: "5") })
  end

  def test_grids_are_counted_in_exact_decimals
    http = FakeHTTP.new(FakeHTTP.json(200, truth_body))
    dn = client(http)
    # 0 to 409.5 at 0.1 is 4,096 values exactly; binary floats would miscount it.
    dn.decide(state: "s", questions: { "q" => DecisionNode.number("n", min: 0, max: 409.5, step: 0.1) })
    dn.decide(state: "s", questions: { "q" => DecisionNode.number("n", min: 0, max: 4095) })
    assert_equal 2, http.calls.size
    assert_refused_locally(DecisionNode::ValidationError, { "q" => DecisionNode.number("n", min: 0, max: 4096) })
  end

  def test_decide_raw_is_never_checked
    http = FakeHTTP.new(FakeHTTP.json(200, truth_body))
    client(http).decide_raw({ "questions" => { "q" => { "type" => "choice", "criteria" => {} } } })
    assert_equal 1, http.calls.size
  end

  # ---- sessions

  def session_body
    { "session_id" => "ses_0123456789abcdef01234567", "model" => "decisionnode-1.0",
      "stream_url" => "wss://api.example.test/v1/sessions/ses_0123456789abcdef01234567/stream",
      "answers" => { "abort" => { "type" => "truth", "truth" => 0.03 } }, "window" => 8 }
  end

  def test_open_session_sends_only_what_is_given_and_always_a_model
    http = FakeHTTP.new(FakeHTTP.json(200, session_body))
    s = client(http).open_session(questions: { abort: DecisionNode.truth("Abort?") }, window: 4)
    assert_equal({ "model" => "decisionnode-latest", "questions" => { "abort" => { "type" => "truth", "instructions" => "Abort?" } },
                   "window" => 4 }, http.calls.first.json)
    assert_equal "ses_0123456789abcdef01234567", s.session_id
    assert_equal 8, s.window
    assert_in_delta 0.03, s.answers["abort"].truth
  end

  def test_the_session_limit_is_never_retried
    limit = FakeHTTP.json(429, { "detail" => { "error_type" => "session_limit_exceeded", "message" => "4 open" } },
                          "retry-after" => "5")
    http = FakeHTTP.new(limit)
    error = assert_raises(DecisionNode::SessionLimitError) do
      client(http, max_retries: 2).open_session(questions: { "q" => DecisionNode.truth("?") })
    end
    assert_kind_of DecisionNode::RateLimitError, error
    assert_in_delta 5.0, error.retry_after
    assert_equal 1, http.calls.size
    # A plain 429 is still retried.
    http = FakeHTTP.new(FakeHTTP.json(429, { "detail" => { "error_type" => "rate_limit_error" } }), FakeHTTP.json(200, session_body))
    client(http, max_retries: 2).open_session(questions: { "q" => DecisionNode.truth("?") })
    assert_equal 2, http.calls.size
  end

  def test_session_closed_reopen_codes
    [1001, 1006, 1011, 4404, 4408, 4409, 4410].each { |code| assert DecisionNode::SessionClosed.new(code).reopen, code.to_s }
    [1000, 1008, 1009, 1013, 4401, 4402, 4403].each { |code| refute DecisionNode::SessionClosed.new(code).reopen, code.to_s }
  end

  def test_session_send_keeps_object_send
    s = DecisionNode::Session.new(client(FakeHTTP.new), session_body)
    assert_equal "ses_0123456789abcdef01234567", s.send(:session_id)
    assert_raises(ArgumentError) { s.send(frame: "x") } # not connected
  end

  # The close code the server sent is kept even where the WebSocket library
  # would replace it (1013 is not in its list).
  class FakeSocket
    attr_reader :written

    def initialize
      @written = +""
    end

    def url
      "ws://127.0.0.1:1/stream"
    end

    def write(data)
      @written << data
    end
  end

  def test_the_server_close_code_is_kept
    socket = FakeSocket.new
    driver = DecisionNode::SessionStream::Driver.new(socket)
    closes = []
    driver.on(:close) { |e| closes << [driver.received_close_code, e.code] }
    driver.start
    key = socket.written[/Sec-WebSocket-Key: (\S+)/, 1]
    accept = [Digest::SHA1.digest("#{key}258EAFA5-E914-47DA-95CA-C5AB0DC85B11")].pack("m0")
    driver.parse("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n" \
                 "Sec-WebSocket-Accept: #{accept}\r\n\r\n")
    payload = [1013].pack("n") + "try again later"
    driver.parse([0x88, payload.bytesize].pack("CC") + payload)
    assert_equal [[1013, 1002]], closes
  end

  # ---- batches

  def batch(state = "draft", extra = {})
    { "id" => "batch_01J9ZB8Q3T", "state" => state, "counters" => { "requests" => 0 }, "ended_at" => nil }.merge(extra)
  end

  def line(id, **rest)
    { custom_id: id, state: "s", questions: { "q" => DecisionNode.truth("?") } }.merge(rest)
  end

  def test_create_sends_json_lines_with_model_and_state
    http = FakeHTTP.new(FakeHTTP.json(201, batch))
    b = client(http).batches.create([line("a"), { "custom_id" => "b", "questions" => { "q" => DecisionNode.truth("?") }, "model" => "decisionnode-1.0" }])
    call = http.calls.first
    assert_equal "application/x-ndjson", call.headers["Content-Type"]
    lines = call.body.split("\n").map { |l| JSON.parse(l) }
    assert_equal %w[custom_id model state questions], lines.first.keys
    assert_equal ["decisionnode-latest", "s"], [lines[0]["model"], lines[0]["state"]]
    assert_equal ["decisionnode-1.0", ""], [lines[1]["model"], lines[1]["state"]]
    assert_instance_of DecisionNode::Batch, b
    assert_equal "draft", b.state
  end

  def test_every_line_is_checked_before_anything_is_sent
    http = FakeHTTP.new(FakeHTTP.json(201, batch))
    error = assert_raises(DecisionNode::BadRequestError) { client(http).batches.create([line("a"), { state: "s" }]) }
    assert_equal ["Line 2 has no custom_id.", "api_usage_error"], [error.message, error.error_type]
    assert_raises(ArgumentError) { client(http).batches.create([line("a"), "not a hash"]) }
    error = assert_raises(DecisionNode::BadRequestError) { client(http).batches.create([line("a"), line("a")]) }
    assert_equal 'Line 2: custom_id "a" is already in the batch.', error.message
    assert_raises(DecisionNode::BadRequestError) { client(http).batches.add("batch_01J9ZB8Q3T", []) }
    assert_raises(DecisionNode::BadRequestError) { client(http).batches.list(limit: 101) }
    assert_raises(DecisionNode::BadRequestError) { client(http).batches.list(offset: -1) }
    assert_raises(DecisionNode::BadRequestError) { client(http).batches.create([line("a"), line("b", questions: { "q" => DecisionNode.choice("?", []) })]) }
    assert_empty http.calls
  end

  def test_add_splits_at_ten_mib_in_order
    http = FakeHTTP.new(FakeHTTP.json(200, batch))
    big = "x" * 4_000_000
    client(http).batches.add("batch_01J9ZB8Q3T", [line("a", state: big), line("b", state: big), line("c", state: big)])
    assert_equal [%w[a b], %w[c]], http.calls.map { |c| c.body.split("\n").map { |l| JSON.parse(l)["custom_id"] } }
    assert(http.calls.all? { |c| c.body.bytesize <= DecisionNode::Batches::ADD_BYTES })
  end

  def test_mutations_are_retried_only_on_429_and_529
    http = FakeHTTP.new(FakeHTTP.json(503, { "detail" => "down" }), FakeHTTP.json(201, batch))
    assert_raises(DecisionNode::ServerError) { client(http).batches.create([]) }
    assert_equal 1, http.calls.size
    http = FakeHTTP.new(DecisionNode::TimeoutError.new("slow"), FakeHTTP.json(201, batch))
    assert_raises(DecisionNode::TimeoutError) { client(http).batches.create([]) }
    assert_equal 1, http.calls.size
    http = FakeHTTP.new(FakeHTTP.json(529, { "detail" => "busy" }), FakeHTTP.json(201, batch))
    client(http).batches.create([])
    assert_equal 2, http.calls.size
    # Reads follow the usual rules.
    http = FakeHTTP.new(FakeHTTP.json(500, { "detail" => "x" }), FakeHTTP.json(200, batch))
    client(http).batches.get("batch_01J9ZB8Q3T")
    assert_equal 2, http.calls.size
  end

  def test_a_finalize_conflict_is_read_with_get
    conflict = FakeHTTP.json(409, { "detail" => { "error_type" => "invalid_batch_state", "message" => "queued" } })
    http = FakeHTTP.new(conflict, FakeHTTP.json(200, batch("queued")))
    assert_equal "queued", client(http).batches.finalize("batch_01J9ZB8Q3T").state
    http = FakeHTTP.new(conflict, FakeHTTP.json(200, batch("draft")))
    error = assert_raises(DecisionNode::DecisionNodeError) { client(http).batches.finalize("batch_01J9ZB8Q3T") }
    assert_equal 409, error.status
  end

  def test_results_parse_every_line_kind
    text = [
      { "custom_id" => "a", "status" => 200, "body" => truth_body(0.88), "headers" => { "x-request-id" => "req_1" } },
      { "custom_id" => "b", "status" => 422, "body" => { "detail" => [{ "type" => "missing" }] }, "headers" => {} },
      { "custom_id" => "c", "status" => "expired", "body" => nil, "headers" => {} }
    ].map { |l| JSON.generate(l) }.join("\n")
    http = FakeHTTP.new(DecisionNode::HTTPResponse.new(200, { "content-type" => "application/x-ndjson" }, "#{text}\n"))
    results = client(http).batches.results("batch_01J9ZB8Q3T")
    assert_in_delta 0.88, results[0].decision["q"].truth
    assert_equal "req_1", results[0].decision.request_id
    assert_instance_of DecisionNode::ValidationError, results[1].error
    assert_equal [{ "type" => "missing" }], results[1].error.entries
    assert_nil results[2].decision
    assert_nil results[2].error
  end

  def test_run_batch_polls_at_the_interval_or_the_longer_retry_after
    ended = batch("completed", "ended_at" => "2026-10-08T10:00:00Z")
    http = FakeHTTP.new(
      FakeHTTP.json(201, batch), FakeHTTP.json(200, batch), FakeHTTP.json(200, batch("queued")),
      FakeHTTP.json(200, batch("running"), "retry-after" => "30"), FakeHTTP.json(200, batch("running"), "retry-after" => "5"),
      FakeHTTP.json(200, ended), DecisionNode::HTTPResponse.new(200, {}, "")
    )
    dn = client(http)
    b, results = dn.run_batch([line("a")], poll_interval: 10)
    assert_equal "completed", b.state
    assert_empty results
    assert_equal [10, 30, 10], dn.sleeps
  end

  def test_run_batch_checks_its_arguments_before_any_request
    http = FakeHTTP.new(FakeHTTP.json(201, batch))
    assert_raises(ArgumentError) { client(http).run_batch([line("a")], poll_interval: 9.9) }
    assert_raises(DecisionNode::BadRequestError) { client(http).run_batch([{ state: "no id" }], poll_interval: 10) }
    assert_empty http.calls
  end

  def test_run_batch_times_out
    http = FakeHTTP.new(FakeHTTP.json(201, batch), FakeHTTP.json(200, batch), FakeHTTP.json(200, batch("queued")),
                        FakeHTTP.json(200, batch("running")))
    assert_raises(DecisionNode::TimeoutError) { client(http).run_batch([line("a")], poll_interval: 10, timeout: 25) }
  end

  def test_run_batch_cancels_the_draft_when_an_add_fails
    http = FakeHTTP.new(FakeHTTP.json(201, batch), FakeHTTP.json(413, { "detail" => "too large" }), FakeHTTP.json(200, batch("cancelled")))
    assert_raises(DecisionNode::DecisionNodeError) { client(http).run_batch([line("a")], poll_interval: 10) }
    assert_equal "https://api.example.test/v1/batches/batch_01J9ZB8Q3T/cancel", http.calls.last.url
  end
end
