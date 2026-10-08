# frozen_string_literal: true

require_relative "test_helper"
require_relative "uploads_test" # its fake API and storage
require "socket"

# Batch results read as a stream, the storage PUT's own timeout, and what a
# session's socket takes from the transport (proxy and TLS settings).
class TransportOptionsTest < Minitest::Test
  include ClientHelpers

  # A transport that streams a 2xx body in the chunks it is given.
  class StreamingHTTP < FakeHTTP
    def initialize(chunks, status: 200, fail_after: nil)
      super()
      @chunks = chunks
      @status = status
      @fail_after = fail_after
    end

    def stream(method, url, headers, timeout)
      @calls << Call.new(method, url, headers, nil, timeout)
      return FakeHTTP.json(@status, { "detail" => "no" }) unless @status == 200

      @chunks.each_with_index do |chunk, i|
        raise DecisionNode::ConnectionError, "dropped" if @fail_after == i

        yield chunk
      end
      DecisionNode::HTTPResponse.new(200, { "content-type" => "application/x-ndjson" }, "")
    end
  end

  def result_lines(count)
    Array.new(count) do |i|
      JSON.generate({ "custom_id" => "r#{i}", "status" => "expired", "body" => nil, "headers" => {} })
    end.join("\n")
  end

  def test_results_are_read_line_by_line_across_chunks
    text = "#{result_lines(1200)}\n"
    chunks = text.scan(/.{1,777}/m) # lines cut mid-way
    dn = client(StreamingHTTP.new(chunks))
    results = dn.batches.results("batch_01J9ZB8Q3T")
    assert_equal 1200, results.size
    assert_equal %w[r0 r599 r1199], [results[0], results[599], results[1199]].map(&:custom_id)

    seen = []
    assert_nil client(StreamingHTTP.new(chunks)).batches.results("batch_01J9ZB8Q3T") { |r| seen << r.custom_id }
    assert_equal 1200, seen.size
  end

  def test_a_last_line_without_a_newline_is_read
    results = client(StreamingHTTP.new([result_lines(2)])).batches.results("batch_01J9ZB8Q3T")
    assert_equal %w[r0 r1], results.map(&:custom_id)
  end

  def test_a_stream_that_fails_after_its_first_line_is_not_retried
    http = StreamingHTTP.new(["#{result_lines(1)}\n", "x"], fail_after: 1)
    assert_raises(DecisionNode::ConnectionError) { client(http, max_retries: 2).batches.results("batch_01J9ZB8Q3T") }
    assert_equal 1, http.calls.size
  end

  def test_an_error_status_is_raised_as_usual
    http = StreamingHTTP.new([], status: 404)
    assert_raises(DecisionNode::NotFoundError) { client(http).batches.results("batch_01J9ZB8Q3T") }
  end

  def test_upload_timeout
    assert_in_delta 60.0, DecisionNode.new(api_key: "k").upload_timeout
    assert_in_delta 120.0, DecisionNode.new(api_key: "k", upload_timeout: 120).upload_timeout
    [0, -1, "x", Float::INFINITY].each do |bad|
      assert_raises(ArgumentError, bad.inspect) { DecisionNode.new(api_key: "k", upload_timeout: bad) }
    end
  end

  def test_the_put_gets_the_upload_timeout_and_api_calls_the_timeout
    api = UploadsTest::FakeAPI.new
    png = File.binread(File.join(__dir__, "fixtures", "images", "image.png"))
    client(api, timeout: 2, upload_timeout: 45, inline_threshold: 0)
      .decide(state: "s", questions: { "q" => DecisionNode.truth("?") }, images: [DecisionNode::Image.new("a", data: png)])
    assert_equal({ "POST" => [2.0], "PUT" => [45.0] }, api.calls.group_by(&:method).transform_values { |c| c.map(&:timeout).uniq })
  end

  def test_the_transport_hands_its_proxy_and_tls_settings_to_sessions
    ca = File.join(__dir__, "fixtures", "images", "image.png") # any path: only carried over
    transport = DecisionNode::NetHTTPTransport.new(proxy: "http://u:p@proxy.example.test:3128",
                                                   net_http: { ca_file: ca, verify_depth: 4, open_timeout: 3 })
    options = transport.session_options
    assert_equal "proxy.example.test", options[:proxy].host
    assert_equal({ "ca_file" => ca, "verify_depth" => 4 }, options[:tls])
    assert_equal :env, DecisionNode::NetHTTPTransport.new.session_options[:proxy]
  end

  def test_the_session_tls_context_keeps_its_checks
    context = DecisionNode::SessionStream.tls_context("ca_file" => "/etc/ssl/company.pem", "verify_depth" => 4,
                                                      "verify_mode" => OpenSSL::SSL::VERIFY_NONE)
    assert_equal "/etc/ssl/company.pem", context.ca_file
    assert_equal 4, context.verify_depth
    assert_equal OpenSSL::SSL::VERIFY_PEER, context.verify_mode
    assert context.verify_hostname
  end

  # A proxy that answers one CONNECT with `status`, then says "hello".
  def fake_proxy(status)
    server = TCPServer.new("127.0.0.1", 0)
    seen = Queue.new
    thread = Thread.new do
      conn = server.accept
      head = +""
      head << conn.readpartial(1024) until head.end_with?("\r\n\r\n")
      seen << head
      conn.write("HTTP/1.1 #{status} Answer\r\n\r\n")
      conn.write("hello") if status == 200
      conn.close
    end
    [URI("http://user:p%40ss@127.0.0.1:#{server.addr[1]}"), seen, thread, server]
  end

  def test_a_wss_socket_goes_through_the_proxy_tunnel
    proxy, seen, thread, server = fake_proxy(200)
    socket = DecisionNode::SessionStream.tunnel(proxy, "api.example.test", 443, 5)
    assert_equal "hello", socket.read(5)
    head = seen.pop
    assert head.start_with?("CONNECT api.example.test:443 HTTP/1.1\r\n"), head
    assert_includes head, "Proxy-Authorization: Basic #{['user:p@ss'].pack('m0')}\r\n"
    socket.close
    thread.join
    server.close
  end

  def test_a_refused_tunnel_is_a_connection_error
    proxy, _seen, thread, server = fake_proxy(407)
    error = assert_raises(DecisionNode::ConnectionError) { DecisionNode::SessionStream.tunnel(proxy, "api.example.test", 443, 5) }
    assert_match(/HTTP 407/, error.message)
    thread.join
    server.close
  end
end
