# frozen_string_literal: true

require_relative "test_helper"
require "digest"

# Images: inline under the threshold, uploaded at or above it, the upload cache
# and the stale-reference resend, against a transport that plays the API and
# the storage.
class UploadsTest < Minitest::Test
  include ClientHelpers

  FIXTURES = File.join(__dir__, "fixtures", "images")
  STORAGE = "https://storage.example.test"

  # A fake API and storage: presigns, stores PUTs, answers decisions.
  class FakeAPI
    attr_reader :calls, :stored

    def initialize(expires_at: "2099-01-01T00:00:00Z", decide: nil, put: nil)
      @expires_at = expires_at
      @decide = decide || ->(_call, _n) { FakeHTTP.json(200, { "answers" => { "q" => { "type" => "truth", "truth" => 0.5 } } }) }
      @put = put || ->(_call, _n) { DecisionNode::HTTPResponse.new(200, {}, "") }
      @calls = []
      @stored = {}
      @lock = Mutex.new
      @counter = 0
    end

    def follow_redirects?
      false
    end

    def call(method, url, headers, body, timeout)
      call = FakeHTTP::Call.new(method, url, headers, body, timeout)
      @lock.synchronize { @calls << call }
      path = URI(url).path
      if method == "POST" && path == "/v1/uploads"
        presign(call)
      elsif method == "PUT"
        @stored[url] = body
        @put.call(call, calls_to("PUT").size)
      elsif path == "/v1/decide" || path == "/v1/systemone"
        @decide.call(call, calls_to("POST", path).size)
      else
        FakeHTTP.json(404, { "detail" => "no route" })
      end
    end

    def calls_to(method, path = nil)
      @lock.synchronize { @calls.select { |c| c.method == method && (path.nil? || URI(c.url).path == path) } }
    end

    private

    def presign(call)
      files = call.json["files"]
      uploads = files.map do |f|
        id = @lock.synchronize { @counter += 1 }
        { "upload_id" => format("upl_%032x", id), "url" => "#{STORAGE}/obj/#{id}?X-Amz-Signature=t",
          "method" => "PUT", "expires_at" => @expires_at,
          "headers" => { "Content-Type" => f["content_type"], "Content-MD5" => f["checksum"], "If-None-Match" => "*",
                         "x-amz-checksum-sha256" => f["sha256"] } }
      end
      FakeHTTP.json(201, { "uploads" => uploads, "expires_in" => 300 })
    end
  end

  def png(pad_to = nil)
    bytes = File.binread(File.join(FIXTURES, "image.png"))
    pad_to ? bytes + ("\0".b * (pad_to - bytes.bytesize)) : bytes
  end

  def question
    { "q" => DecisionNode.truth("Does the receipt total equal the claim?") }
  end

  def test_small_images_go_inline_with_no_upload
    api = FakeAPI.new
    client(api).decide(state: "s", questions: question, images: [DecisionNode::Image.new("a", data: png)])
    assert_equal 1, api.calls.size
    image = api.calls.first.json["images"].first
    assert_equal({ "id" => "a", "media_type" => "image/png", "data" => [png].pack("m0") }, image)
  end

  def test_the_threshold_counts_every_local_image_of_the_request
    api = FakeAPI.new
    half = DecisionNode::DEFAULT_INLINE_THRESHOLD / 2
    images = [DecisionNode::Image.new("a", data: png(half)), DecisionNode::Image.new("b", data: png(half + 1)),
              DecisionNode::Image.new("u", url: "https://example.com/u.png")]
    client(api).decide(state: "s", questions: question, images: images)
    presign = api.calls_to("POST", "/v1/uploads")
    assert_equal 1, presign.size
    files = presign.first.json["files"]
    assert_equal [half, half + 1], files.map { |f| f["byte_size"] }
    assert_equal [Digest::MD5.base64digest(png(half)), Digest::SHA256.base64digest(png(half))],
                 [files[0]["checksum"], files[0]["sha256"]]
    sent = api.calls_to("POST", "/v1/decide").first.json["images"]
    assert_equal %w[a b u], sent.map { |i| i["id"] }
    assert_match(/\Aupl_/, sent[0]["upload_id"])
    assert_nil sent[0]["data"]
    assert_equal({ "id" => "u", "url" => "https://example.com/u.png" }, sent[2])
  end

  def test_under_the_threshold_by_one_byte_is_inline
    api = FakeAPI.new
    image = DecisionNode::Image.new("a", data: png(DecisionNode::DEFAULT_INLINE_THRESHOLD - 1))
    client(api).decide(state: "s", questions: question, images: [image])
    assert_empty api.calls_to("POST", "/v1/uploads")
  end

  def test_inline_threshold_option
    api = FakeAPI.new
    client(api, inline_threshold: 0).decide(state: "s", questions: question, images: [DecisionNode::Image.new("a", data: png)])
    assert_equal 1, api.calls_to("POST", "/v1/uploads").size
    assert_raises(ArgumentError) { DecisionNode.new(api_key: "k", inline_threshold: -1) }
    assert_raises(ArgumentError) { DecisionNode.new(api_key: "k", inline_threshold: 1.5) }
  end

  def test_the_put_carries_exactly_the_returned_headers
    api = FakeAPI.new
    dn = client(api, headers: { "x-team" => "ops" }, inline_threshold: 0)
    dn.decide(state: "s", questions: question, images: [DecisionNode::Image.new("a", data: png)])
    put = api.calls_to("PUT").first
    assert_equal %w[Content-Type Content-MD5 If-None-Match x-amz-checksum-sha256].sort, put.headers.keys.sort
    assert_equal png, put.body
  end

  def test_puts_run_in_parallel_and_one_presign_covers_them
    started = Queue.new
    release = Queue.new
    put = lambda do |_call, _n|
      started << true
      release.pop
      DecisionNode::HTTPResponse.new(200, {}, "")
    end
    api = FakeAPI.new(put: put)
    images = Array.new(3) { |i| DecisionNode::Image.new("i#{i}", data: png(200_000 + i)) }
    worker = Thread.new { client(api).decide(state: "s", questions: question, images: images) }
    3.times { started.pop } # all three PUTs are in flight at once
    3.times { release << true }
    worker.join
    assert_equal 1, api.calls_to("POST", "/v1/uploads").size
  end

  def test_the_cache_reuses_an_upload_whatever_the_size
    api = FakeAPI.new
    dn = client(api)
    big = DecisionNode::Image.new("big", data: png(600_000))
    small = DecisionNode::Image.new("small", data: File.binread(File.join(FIXTURES, "baseline.jpg")))
    dn.decide(state: "s", questions: question, images: [big, small])
    dn.decide(state: "s", questions: question, images: [DecisionNode::Image.new("again", data: small.data)])
    assert_equal 1, api.calls_to("POST", "/v1/uploads").size
    second = api.calls_to("POST", "/v1/decide").last.json["images"].first
    assert_equal "again", second["id"]
    assert_match(/\Aupl_/, second["upload_id"])
  end

  def test_an_entry_is_not_used_in_the_last_five_minutes
    soon = (Time.now + 200).utc.iso8601
    api = FakeAPI.new(expires_at: soon)
    dn = client(api)
    2.times { dn.decide(state: "s", questions: question, images: [DecisionNode::Image.new("a", data: png(600_000))]) }
    assert_equal 2, api.calls_to("POST", "/v1/uploads").size
  end

  def test_upload_always_uploads_and_returns_the_ids
    api = FakeAPI.new
    dn = client(api)
    ids = dn.upload([DecisionNode::Image.new("a", data: png), DecisionNode::Image.new("b", data: png)])
    assert_equal 1, ids.uniq.size # the same bytes are one upload
    assert_equal 1, api.calls_to("PUT").size
    assert_equal ids, dn.upload([DecisionNode::Image.new("c", data: png), DecisionNode::Image.new("d", data: png)])
    assert_equal 1, api.calls_to("POST", "/v1/uploads").size
    assert_raises(ArgumentError) { dn.upload([DecisionNode::Image.new("u", url: "https://example.com/u.png")]) }
  end

  def stale(type)
    FakeHTTP.json(400, { "detail" => { "error_type" => type, "message" => "stale" } })
  end

  def test_a_stale_upload_is_uploaded_again_and_sent_once_more
    DecisionNode::Uploads::STALE_UPLOAD.each do |type|
      decide = ->(_call, n) { n == 1 ? stale(type) : FakeHTTP.json(200, truth_body) }
      api = FakeAPI.new(decide: decide)
      dn = client(api, max_retries: 0)
      dn.decide(state: "s", questions: question, images: [DecisionNode::Image.new("a", data: png(600_000))])
      assert_equal 2, api.calls_to("POST", "/v1/uploads").size, type
      ids = api.calls_to("POST", "/v1/decide").map { |c| c.json.dig("images", 0, "upload_id") }
      refute_equal ids[0], ids[1], type
    end
  end

  def test_a_second_stale_answer_raises
    api = FakeAPI.new(decide: ->(_call, _n) { stale("upload_expired") })
    error = assert_raises(DecisionNode::BadRequestError) do
      client(api).decide(state: "s", questions: question, images: [DecisionNode::Image.new("a", data: png(600_000))])
    end
    assert_equal "upload_expired", error.error_type
    assert_equal 2, api.calls_to("POST", "/v1/decide").size
  end

  def test_an_upload_id_given_by_the_caller_is_never_uploaded_again
    api = FakeAPI.new(decide: ->(_call, _n) { stale("upload_not_found") })
    image = DecisionNode::Image.new("r", upload_id: "upl_00000000000000000000000000000000")
    assert_raises(DecisionNode::BadRequestError) { client(api).decide(state: "s", questions: question, images: [image]) }
    assert_equal 1, api.calls.size
    assert_equal({ "id" => "r", "upload_id" => "upl_00000000000000000000000000000000" }, api.calls.first.json["images"].first)
  end

  def s3_error(status, code)
    DecisionNode::HTTPResponse.new(status, { "content-type" => "application/xml" },
                                   "<?xml version=\"1.0\"?><Error><Code>#{code}</Code></Error>")
  end

  def test_put_retries_on_5xx_and_a_412_on_a_retry_is_success
    api = FakeAPI.new(put: ->(_call, n) { n == 1 ? s3_error(500, "InternalError") : s3_error(412, "PreconditionFailed") })
    dn = client(api)
    dn.decide(state: "s", questions: question, images: [DecisionNode::Image.new("a", data: png(600_000))])
    assert_equal 2, api.calls_to("PUT").size
    assert_equal 1, dn.sleeps.size
  end

  def test_put_failures_are_upload_failed_errors
    [[400, "BadDigest"], [403, "SignatureDoesNotMatch"], [412, "PreconditionFailed"], [307, nil]].each do |status, code|
      api = FakeAPI.new(put: ->(_call, _n) { code ? s3_error(status, code) : DecisionNode::HTTPResponse.new(status, {}, "") })
      error = assert_raises(DecisionNode::DecisionNodeError) do
        client(api).decide(state: "s", questions: question, images: [DecisionNode::Image.new("a", data: png(600_000))])
      end
      assert_instance_of DecisionNode::DecisionNodeError, error
      assert_equal [status, "upload_failed", code], [error.status, error.error_type, error.reason]
      assert_equal 1, api.calls_to("PUT").size, status.to_s
      assert_empty api.calls_to("POST", "/v1/decide")
    end
  end

  def test_a_storage_url_over_plain_http_is_refused_before_any_byte
    api = FakeAPI.new
    api.define_singleton_method(:presign) do |call|
      files = call.json["files"]
      FakeHTTP.json(201, { "uploads" => files.map { { "upload_id" => "upl_x", "url" => "http://storage.example.com/o", "headers" => {} } } })
    end
    assert_raises(DecisionNode::DecisionNodeError) do
      client(api).decide(state: "s", questions: question, images: [DecisionNode::Image.new("a", data: png(600_000))])
    end
    assert_empty api.calls_to("PUT")
  end

  def test_concurrent_requests_with_the_same_bytes_upload_once
    api = FakeAPI.new(put: lambda do |_call, _n|
      sleep 0.05 # long enough for the other requests to arrive mid-upload
      DecisionNode::HTTPResponse.new(200, {}, "")
    end)
    big = png(600_000)
    requests = Array.new(6) { |i| { state: "s#{i}", questions: question, images: [DecisionNode::Image.new("r", data: big)] } }
    results = client(api).decide_many(requests, concurrency: 6)
    assert(results.all?(DecisionNode::Decision))
    assert_equal 1, api.calls_to("POST", "/v1/uploads").size
    assert_equal 1, api.calls_to("PUT").size
    ids = api.calls_to("POST", "/v1/decide").map { |c| c.json.dig("images", 0, "upload_id") }
    assert_equal 1, ids.uniq.size
  end
end
