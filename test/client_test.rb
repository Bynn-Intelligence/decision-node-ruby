# frozen_string_literal: true

require "test_helper"
require "logger"
require "stringio"
require "socket"
require "tmpdir"

class ClientTest < Minitest::Test
  include ClientHelpers

  def test_decide_sends_the_wire_form
    http = FakeHTTP.new(FakeHTTP.json(200, truth_body))
    client(http).decide(state: { "ticket" => "charged twice" }, questions: { q: DecisionNode.truth("Escalate?") })
    call = http.calls.first
    assert_equal "POST", call.method
    assert_equal "https://api.example.test/v1/decide", call.url
    assert_equal "Bearer dn_test_key", call.headers["Authorization"]
    assert_equal "application/json", call.headers["Content-Type"]
    assert_equal "decisionnode-ruby/#{DecisionNode::VERSION}", call.headers["User-Agent"]
    assert_equal({ "model" => "decisionnode-latest", "state" => { "ticket" => "charged twice" },
                   "questions" => { "q" => { "type" => "truth", "instructions" => "Escalate?" } } }, call.json)
  end

  def test_state_defaults_to_empty_string
    http = FakeHTTP.new(FakeHTTP.json(200, truth_body))
    client(http).decide(questions: { "q" => DecisionNode.truth("?") })
    assert_equal "", http.calls.first.json["state"]
  end

  def test_models_is_a_get_without_body
    http = FakeHTTP.new(FakeHTTP.json(200, { "models" => [{ "name" => "decisionnode-1.0" }] }))
    models = client(http).models
    assert_equal "GET", http.calls.first.method
    assert_nil http.calls.first.body
    refute http.calls.first.headers.key?("Content-Type")
    assert_equal "decisionnode-1.0", models.first.name
  end

  def test_decide_raw_sends_the_body_as_given
    body = { "state" => "s", "questions" => { "q" => { "type" => "truth", "instructions" => "?" } }, "extra" => 1 }
    http = FakeHTTP.new(FakeHTTP.json(200, truth_body))
    raw = client(http).decide_raw(body)
    assert_equal body, http.calls.first.json
    assert_equal truth_body, raw
  end

  def test_helpers_use_fixed_question_ids
    http = FakeHTTP.new(lambda do |call|
      id, q = call.json["questions"].first
      answer = { "type" => q["type"], "truth" => 0.1, "choice" => "a", "score" => 1.0, "confidence" => 0.9,
                 "probabilities" => {}, "legend" => {} }
      FakeHTTP.json(200, { "model" => "decisionnode-1.0", "answers" => { id => answer } })
    end)
    dn = client(http)
    assert_instance_of DecisionNode::TruthAnswer, dn.check(state: "s", instructions: "?", if_true: "y")
    assert_instance_of DecisionNode::ChoiceAnswer, dn.classify(state: "s", instructions: "?", options: %w[a b])
    assert_instance_of DecisionNode::ScoreAnswer, dn.score(state: "s", instructions: "?", levels: %w[lo hi])
    assert_equal %w[check classify score], http.calls.map { |c| c.json["questions"].keys.first }
  end

  def test_gate
    http = FakeHTTP.new(FakeHTTP.json(200, truth_body))
    client(http).gate(action: "DROP TABLE invoices;", context: { "environment" => "production" })
    body = http.calls.first.json
    assert_equal({ "action" => "DROP TABLE invoices;", "context" => { "environment" => "production" } }, body["state"])
    assert_equal %w[risk touches_production verdict], body["questions"].keys
    assert_equal DecisionNode::GATE_QUESTIONS, body["questions"]
    assert_equal({ "type" => "score", "instructions" => "How much harm could this action cause if it is wrong?",
                   "criteria" => %w[none low moderate high severe] }, body["questions"]["risk"])
    assert_equal %w[allow confirm block], body["questions"]["verdict"]["criteria"].keys
  end

  def test_images
    png = File.binread(File.join(__dir__, "fixtures", "images", "image.png"))
    http = FakeHTTP.new(FakeHTTP.json(200, truth_body))
    client(http).decide(questions: { "q" => DecisionNode.truth("?") },
                        images: [DecisionNode::Image.new("a", data: png),
                                 DecisionNode::Image.new("b", url: "https://example.com/b.jpg")])
    images = http.calls.first.json["images"]
    assert_equal({ "id" => "a", "media_type" => "image/png", "data" => [png].pack("m0") }, images[0])
    assert_equal({ "id" => "b", "url" => "https://example.com/b.jpg" }, images[1])
  end

  def test_image_argument_errors_are_raised_where_the_image_is_made
    assert_raises(ArgumentError) { DecisionNode::Image.new("a", path: "/nonexistent/file.png") }
    assert_raises(ArgumentError) { DecisionNode::Image.new("a", data: 42) }
    assert_raises(ArgumentError) { DecisionNode::Image.new("a") }
    assert_raises(ArgumentError) { DecisionNode::Image.new("a", url: "https://example.com/a.png", data: "x") }
  end

  def test_image_faults_are_bad_requests_before_sending
    http = FakeHTTP.new(FakeHTTP.json(200, truth_body))
    error = assert_raises(DecisionNode::BadRequestError) do
      client(http).decide(questions: { "q" => DecisionNode.truth("?") },
                          images: [DecisionNode::Image.new("a", data: "plain text")])
    end
    assert_equal "api_usage_error", error.error_type
    assert_nil error.status
    assert_nil error.request_id
    assert_empty http.calls
  end

  def test_image_bytes_without_media_type_are_sniffed
    jpeg = File.binread(File.join(__dir__, "fixtures", "images", "baseline.jpg"))
    assert_equal "image/jpeg", DecisionNode::Image.new("a", data: jpeg).media_type
    assert_equal "image/jpeg", DecisionNode::Image.new("a", data: jpeg, media_type: "").media_type
    # A declared type that differs from the bytes is refused before sending.
    mismatch = DecisionNode::Image.new("a", data: jpeg, media_type: "image/png")
    assert_raises(DecisionNode::BadRequestError) { mismatch.validate! }
  end

  def test_image_file_is_read_when_made
    Dir.mktmpdir do |dir|
      path = File.join(dir, "a.png")
      File.binwrite(path, File.binread(File.join(__dir__, "fixtures", "images", "image.png")))
      image = DecisionNode::Image.new("a", path: path)
      File.delete(path)
      assert_equal "image/png", image.to_h["media_type"]
    end
  end

  def test_image_sniffing
    assert_equal "image/jpeg", DecisionNode::Image.sniff_media_type("\xFF\xD8\xFF\xE0".b)
    assert_equal "image/webp", DecisionNode::Image.sniff_media_type("RIFF\x00\x00\x00\x00WEBPVP8 ".b)
    assert_nil DecisionNode::Image.sniff_media_type("GIF89a")
  end

  def test_empty_questions_fail_before_sending
    http = FakeHTTP.new(FakeHTTP.json(200, truth_body))
    assert_raises(ArgumentError) { client(http).decide(state: "s", questions: {}) }
    assert_empty http.calls
  end

  def test_unserialisable_value_fails_before_sending
    http = FakeHTTP.new(FakeHTTP.json(200, truth_body))
    assert_raises(ArgumentError) do
      client(http).decide(state: { "reading" => Float::NAN }, questions: { "q" => DecisionNode.truth("?") })
    end
    assert_empty http.calls
  end

  def test_missing_key_fails_before_sending
    http = FakeHTTP.new(FakeHTTP.json(200, truth_body))
    dn = DecisionNode.new(http_client: http)
    assert_raises(DecisionNode::AuthenticationError) { dn.decide(questions: { "q" => DecisionNode.truth("?") }) }
    assert_empty http.calls
  end

  def test_environment_and_precedence
    ENV["DECISIONNODE_API_KEY"] = "env_key"
    ENV["DECISIONNODE_BASE_URL"] = "https://env.example.test/"
    ENV["DECISIONNODE_MODEL"] = "decisionnode-flash-latest"
    dn = DecisionNode.new
    assert_equal "https://env.example.test", dn.base_url
    assert_equal "decisionnode-flash-latest", dn.model
    dn = DecisionNode.new(model: "decisionnode-1.0", base_url: "https://arg.example.test")
    assert_equal "decisionnode-1.0", dn.model
    assert_equal "https://arg.example.test", dn.base_url
    refute_includes dn.inspect, "env_key"
  end

  def test_empty_arguments_count_as_not_given
    ENV["DECISIONNODE_API_KEY"] = "env_key"
    ENV["DECISIONNODE_BASE_URL"] = "https://env.example.test"
    ENV["DECISIONNODE_MODEL"] = "decisionnode-1.0"
    http = FakeHTTP.new(FakeHTTP.json(200, truth_body))
    dn = DecisionNode.new(api_key: "", base_url: "", model: "", http_client: http)
    assert_equal "https://env.example.test", dn.base_url
    assert_equal "decisionnode-1.0", dn.model
    dn.decide(questions: { "q" => DecisionNode.truth("?") }, model: "")
    assert_equal "Bearer env_key", http.calls.first.headers["Authorization"]
    assert_equal "decisionnode-1.0", http.calls.first.json["model"]
    ENV.delete("DECISIONNODE_BASE_URL")
    ENV.delete("DECISIONNODE_MODEL")
    dn = DecisionNode.new(base_url: "", model: "")
    assert_equal "https://api.decisionnode.com", dn.base_url
    assert_equal "decisionnode-latest", dn.model
  end

  def test_helpers_take_images_and_model
    http = FakeHTTP.new(lambda do |call|
      answers = call.json["questions"].to_h do |id, q|
        answer =
          case q["type"]
          when "truth" then { "type" => "truth", "truth" => 0.5 }
          when "choice" then { "type" => "choice", "choice" => "a", "confidence" => 0.5,
                               "probabilities" => { "a" => 0.5, "b" => 0.5 } }
          else { "type" => "score", "score" => 0.5, "confidence" => 0.5,
                 "probabilities" => { "0" => 0.5, "1" => 0.5 }, "legend" => { "0" => "lo", "1" => "hi" } }
          end
        [id, answer]
      end
      FakeHTTP.json(200, { "answers" => answers })
    end)
    dn = client(http)
    img = DecisionNode::Image.new("i", url: "https://example.com/i.png")
    dn.check(state: "s", instructions: "?", images: [img], model: "decisionnode-1.0-flash")
    dn.classify(state: "s", instructions: "?", options: %w[a b], images: [img], model: "decisionnode-1.0-flash")
    dn.score(state: "s", instructions: "?", levels: %w[lo hi], images: [img], model: "decisionnode-1.0-flash")
    dn.gate(action: "a", images: [img], model: "decisionnode-1.0-flash")
    http.calls.each do |c|
      assert_equal "decisionnode-1.0-flash", c.json["model"]
      assert_equal [{ "id" => "i", "url" => "https://example.com/i.png" }], c.json["images"]
    end
  end

  def test_spec_version_and_user_agent
    assert_equal "1.1", DecisionNode::SPEC_VERSION
    assert_equal 524_288, DecisionNode::DEFAULT_INLINE_THRESHOLD
    http = FakeHTTP.new(FakeHTTP.json(200, truth_body))
    client(http).decide(questions: { "q" => DecisionNode.truth("?") })
    assert_equal "decisionnode-ruby/#{DecisionNode::VERSION}", http.calls.first.headers["User-Agent"]
  end

  def test_defaults
    dn = DecisionNode.new
    assert_equal "https://api.decisionnode.com", dn.base_url
    assert_equal "decisionnode-latest", dn.model
    assert_in_delta 10.0, dn.timeout
    assert_equal 2, dn.max_retries
    assert_same DecisionNode, DecisionNode::Client
  end

  def test_plain_http_only_for_loopback
    %w[http://localhost:8080 http://127.0.0.1:9 http://[::1]:9 HTTP://LOCALHOST https://api.example.test].each do |url|
      assert_equal url, DecisionNode.new(base_url: url).base_url
    end
    %w[http://api.example.test http://10.0.0.1 http://localhost.example.test ftp://api.example.test
       api.example.test https://].each do |url|
      assert_raises(ArgumentError, url) { DecisionNode.new(base_url: url) }
    end
    ENV["DECISIONNODE_BASE_URL"] = "http://api.example.test"
    assert_raises(ArgumentError) { DecisionNode.new }
  end

  def test_timeout_and_max_retries_are_checked
    [0, -1, 0.0, "0", Float::NAN, Float::INFINITY, nil.to_a, "soon"].each do |t|
      assert_raises(ArgumentError, t.inspect) { DecisionNode.new(timeout: t) }
    end
    [-1, "-2", 1.5, "x", []].each do |n|
      assert_raises(ArgumentError, n.inspect) { DecisionNode.new(max_retries: n) }
    end
    dn = DecisionNode.new(timeout: "0.25", max_retries: 0)
    assert_in_delta 0.25, dn.timeout
    assert_equal 0, dn.max_retries
    assert_equal 3, DecisionNode.new(max_retries: 3.0).max_retries
  end

  def test_timeout_covers_the_whole_attempt
    # A transport that keeps receiving bytes, each well within any per-step
    # timeout, still ends at the attempt's deadline.
    slow = Object.new
    def slow.call(*)
      20.times { sleep 0.05 }
      FakeHTTP.json(200, { "answers" => {} })
    end

    def slow.follow_redirects? = false
    dn = client(slow, timeout: 0.2, max_retries: 0)
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    assert_raises(DecisionNode::TimeoutError) { dn.decide(questions: { "q" => DecisionNode.truth("?") }) }
    assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - started, :<, 0.6
  end

  def test_timeout_covers_a_trickled_body_on_the_default_transport
    server = TCPServer.new("127.0.0.1", 0)
    port = server.addr[1]
    thread = Thread.new do
      sock = server.accept
      sock.readpartial(65_536)
      sock.write("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 40\r\n\r\n")
      40.times do
        sock.write(" ")
        sleep 0.05
      end
    rescue StandardError
      nil
    ensure
      sock&.close
    end
    dn = DecisionNode.new(api_key: "k", base_url: "http://127.0.0.1:#{port}", timeout: 0.3, max_retries: 0)
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    assert_raises(DecisionNode::TimeoutError) { dn.decide(questions: { "q" => DecisionNode.truth("?") }) }
    assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - started, :<, 1.0
  ensure
    thread&.kill
    server&.close
  end

  def test_a_transport_that_follows_redirects_is_refused
    follower = FakeHTTP.new(FakeHTTP.json(200, truth_body))
    def follower.follow_redirects?
      true
    end
    assert_raises(ArgumentError) { DecisionNode.new(http_client: follower) }
    assert_raises(ArgumentError) { DecisionNode.new(http_client: Object.new) }
    undeclared = Object.new
    def undeclared.call(*) = nil
    assert_raises(ArgumentError) { DecisionNode.new(http_client: undeclared) }
    refute DecisionNode::NetHTTPTransport.new.follow_redirects?
  end

  def test_a_response_from_another_url_is_an_error
    moved = FakeHTTP.json(200, truth_body)
    moved.url = "https://elsewhere.example.test/v1/decide"
    err = assert_raises(DecisionNode::DecisionNodeError) do
      client(FakeHTTP.new(moved), max_retries: 0).decide(questions: { "q" => DecisionNode.truth("?") })
    end
    assert_instance_of DecisionNode::DecisionNodeError, err
  end

  def test_transport_options
    transport = DecisionNode::NetHTTPTransport.new(proxy: "http://proxy.example.test:3128",
                                                   net_http: { verify_mode: OpenSSL::SSL::VERIFY_PEER })
    http = transport.send(:new_http, URI("https://api.example.test"))
    assert_equal "proxy.example.test", http.proxy_address
    assert_equal OpenSSL::SSL::VERIFY_PEER, http.verify_mode
    assert_raises(ArgumentError) { DecisionNode::NetHTTPTransport.new(net_http: { no_such_setting: 1 }) }
  end

  def test_transport_settings_cannot_turn_tls_off
    [
      { use_ssl: false },
      { "use_ssl=" => true },
      { verify_mode: OpenSSL::SSL::VERIFY_NONE },
      { "verify_mode=" => OpenSSL::SSL::VERIFY_NONE },
      { verify_hostname: false },
      { verify_callback: ->(_ok, _ctx) { true } }
    ].each do |opts|
      assert_raises(ArgumentError, opts.inspect) { DecisionNode::NetHTTPTransport.new(net_http: opts) }
    end
    transport = DecisionNode::NetHTTPTransport.new(net_http: { verify_hostname: true, ca_file: "/dev/null" })
    http = transport.send(:new_http, URI("https://api.example.test"))
    assert http.use_ssl?
    assert_equal OpenSSL::SSL::VERIFY_PEER, http.verify_mode
    assert_equal true, http.verify_hostname
    assert_nil http.verify_callback
  end

  def test_tls_is_set_again_after_the_callers_settings
    transport = DecisionNode::NetHTTPTransport.new
    # Settings that slipped past the check are overridden for an https URL.
    transport.instance_variable_set(:@net_http, { "verify_mode=": OpenSSL::SSL::VERIFY_NONE, "verify_hostname=": false })
    http = transport.send(:new_http, URI("https://api.example.test"))
    assert http.use_ssl?
    assert_equal OpenSSL::SSL::VERIFY_PEER, http.verify_mode
    assert_equal true, http.verify_hostname
  end

  def test_helpers_raise_server_error_for_a_missing_or_malformed_answer
    cases = {
      check: [{ instructions: "?" }, { "type" => "truth", "truth" => "0.9" }],
      classify: [{ instructions: "?", options: %w[a b] }, { "type" => "choice", "choice" => "a", "confidence" => 0.5 }],
      score: [{ instructions: "?", levels: %w[lo hi] }, { "type" => "score", "score" => 1, "confidence" => 0.5,
                                                            "probabilities" => [0.5, 0.5], "legend" => { "0" => "lo" } }]
    }
    cases.each do |method, (args, answer)|
      [{ method.to_s => answer }, {}].each do |answers|
        http = FakeHTTP.new(FakeHTTP.json(200, { "answers" => answers },
                                          { "x-request-id" => "req_1", "x-decisionnode-error" => "could not answer" }))
        err = assert_raises(DecisionNode::ServerError) { client(http).public_send(method, state: "s", **args) }
        assert_equal 200, err.status
        assert_equal "req_1", err.request_id
        assert_equal "could not answer", err.reason
      end
    end
    # decide with the same answer returns an UnknownAnswer.
    http = FakeHTTP.new(FakeHTTP.json(200, { "answers" => { "q" => { "type" => "truth", "truth" => "0.9" } } }))
    assert_instance_of DecisionNode::UnknownAnswer, client(http).decide(questions: { "q" => DecisionNode.truth("?") })["q"]
  end

  def test_no_extra_error_classes
    errors = DecisionNode.constants.select do |name|
      value = DecisionNode.const_get(name)
      value.is_a?(Class) && value <= DecisionNode::DecisionNodeError
    end
    expected = %w[DecisionNodeError BadRequestError ContextLimitError AuthenticationError InsufficientCreditError
                  PermissionDeniedError RefusalError NotFoundError ValidationError RateLimitError OverloadedError
                  ServerError ConnectionError TimeoutError SessionLimitError]
    assert_equal expected.sort, errors.map(&:to_s).sort
    # The one subclass spec 1.1 adds is a RateLimitError, so a rescue of 429s catches it.
    assert_operator DecisionNode::SessionLimitError, :<, DecisionNode::RateLimitError
    # The end of a session's stream is a session value, not an API error.
    refute_operator DecisionNode::SessionClosed, :<, DecisionNode::DecisionNodeError
  end

  def test_logger_never_prints_the_body
    out = StringIO.new
    logger = Logger.new(out, level: Logger::DEBUG)
    http = FakeHTTP.new(FakeHTTP.json(200, truth_body, "x-request-id" => "req_9"))
    client(http, logger: logger).decide(state: "secret state", questions: { "q" => DecisionNode.truth("secret?") })
    assert_match %r{POST /v1/decide -> 200 request_id=req_9}, out.string
    refute_includes out.string, "secret"
  end
end
