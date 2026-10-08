# frozen_string_literal: true

require_relative "test_helper"

# Videos sent as frames: the wire form, where videos go, the local checks and
# the video fields of a decision.
class VideoTest < Minitest::Test
  include ClientHelpers

  FIXTURES = File.join(__dir__, "fixtures", "images")

  def jpeg
    File.binread(File.join(FIXTURES, "baseline.jpg"))
  end

  def frames(*times)
    times.map { |t| DecisionNode::Frame.new(t, data: jpeg) }
  end

  def decide_video(dn, video, **kw)
    dn.decide(state: "s", questions: { "q" => DecisionNode.truth("?") }, videos: [video], **kw)
  end

  def refused(dn = client(FakeHTTP.new(FakeHTTP.json(200, truth_body))), &block)
    error = assert_raises(DecisionNode::BadRequestError) { block.call(dn) }
    assert_nil error.status
    assert_nil error.request_id
    assert_equal "api_usage_error", error.error_type
    error.message
  end

  def test_wire_form
    http = FakeHTTP.new(FakeHTTP.json(200, truth_body))
    dn = client(http)
    text = [jpeg].pack("m0")
    video = DecisionNode::Video.new("dock", frames: [DecisionNode::Frame.new(30, data: jpeg),
                                                     DecisionNode::Frame.new(30.5, base64: text, media_type: "image/png")],
                                            fps: 2, start: 30, end: 31.5)
    decide_video(dn, video)
    body = http.calls.first.json
    assert_equal [{ "id" => "dock", "fps" => 2, "start" => 30, "end" => 31.5,
                    "frames" => [{ "t" => 30, "media_type" => "image/jpeg", "data" => text },
                                 { "t" => 30.5, "media_type" => "image/png", "data" => text }] }], body["videos"]
    assert_equal %w[id fps start end frames], body["videos"][0].keys
    assert_equal %w[model state questions videos], body.keys
  end

  def test_optional_fields_left_out_and_empty_list_left_out
    http = FakeHTTP.new(FakeHTTP.json(200, truth_body))
    dn = client(http)
    decide_video(dn, DecisionNode::Video.new("cam", frames: frames(0)))
    assert_equal %w[id frames], http.calls.last.json["videos"][0].keys
    dn.decide(state: "s", questions: { "q" => DecisionNode.truth("?") }, videos: [])
    refute http.calls.last.json.key?("videos")
  end

  def test_frames_never_count_toward_the_inline_threshold
    http = FakeHTTP.new(FakeHTTP.json(200, truth_body))
    dn = client(http, inline_threshold: 1)
    decide_video(dn, DecisionNode::Video.new("cam", frames: frames(0, 0.5)))
    assert_equal 1, http.calls.size
    assert_equal "/v1/decide", URI(http.calls.first.url).path
  end

  def test_plain_wire_form_and_symbol_keys
    http = FakeHTTP.new(FakeHTTP.json(200, truth_body))
    dn = client(http)
    data = [jpeg].pack("m0")
    decide_video(dn, { id: "cam", fps: 1, frames: [{ t: 0, media_type: "image/jpeg", data: data }] })
    assert_equal [{ "id" => "cam", "fps" => 1, "frames" => [{ "t" => 0, "media_type" => "image/jpeg", "data" => data }] }],
                 http.calls.first.json["videos"]
  end

  def test_videos_in_systemone_helpers_and_batch_lines
    http = FakeHTTP.new(FakeHTTP.json(200, truth_body(id: "check")))
    dn = client(http)
    video = DecisionNode::Video.new("cam", frames: frames(0))
    dn.check(state: "s", instructions: "?", videos: [video])
    assert_equal "cam", http.calls.last.json["videos"][0]["id"]
    line = dn.send(:batch_line, { custom_id: "a", questions: { "q" => DecisionNode.truth("?") }, videos: [video] }, 0)
    assert_equal "cam", JSON.parse(line)["videos"][0]["id"]
    assert_nil dn.check_request("systemone", state: "s", questions: { "q" => DecisionNode.truth("?") }, videos: [video])
  end

  def test_local_checks_in_the_api_order_and_words
    five = Array.new(5) { |i| DecisionNode::Video.new("v#{i}", frames: frames(0)) }
    assert_equal "Too many videos: 5, the limit is 4.",
                 refused { |dn| dn.decide(questions: { "q" => DecisionNode.truth("?") }, videos: five) }
    assert_equal "Video 0 needs an id.", refused { |dn| decide_video(dn, DecisionNode::Video.new("", frames: frames(0))) }
    shared = refused do |dn|
      dn.decide(questions: { "q" => DecisionNode.truth("?") }, images: [DecisionNode::Image.new("gate", url: "https://example.com/g.jpg")],
                videos: [DecisionNode::Video.new("gate", frames: frames(0))])
    end
    assert_equal "Video id 'gate' is used twice (ids are unique across images and videos).", shared
    assert_equal "Video 'cam': frames must be a non-empty list of frames.",
                 refused { |dn| decide_video(dn, DecisionNode::Video.new("cam", frames: [])) }
    assert_equal "Video 'cam': frame 0: t must be a number of seconds, at least 0.",
                 refused { |dn| decide_video(dn, DecisionNode::Video.new("cam", frames: frames(-0.5))) }
    assert_equal "Video 'cam': frame 1: t must be larger than the frame before it (1.5).",
                 refused { |dn| decide_video(dn, DecisionNode::Video.new("cam", frames: frames(1.5, 1.5))) }
    assert_equal "Video 'cam': frame 1: t must be larger than the frame before it (1e+06).",
                 refused { |dn| decide_video(dn, DecisionNode::Video.new("cam", frames: frames(1_000_000, 2))) }
    gif = DecisionNode::Frame.new(0, data: "GIF89a\x01\x00".b)
    assert_equal "Video 'cam': frame 0: media_type must be one of image/jpeg, image/png, image/webp.",
                 refused { |dn| decide_video(dn, DecisionNode::Video.new("cam", frames: [gif])) }
    no_type = DecisionNode::Frame.new(0, base64: [jpeg].pack("m0"))
    assert_equal "Video 'cam': frame 0: media_type must be one of image/jpeg, image/png, image/webp.",
                 refused { |dn| decide_video(dn, DecisionNode::Video.new("cam", frames: [no_type])) }
    [5, 0, -1].each do |fps|
      assert_equal "Video 'cam': fps must be a number above 0 and at most 4.",
                   refused { |dn| decide_video(dn, DecisionNode::Video.new("cam", frames: frames(0), fps: fps)) }
    end
    assert_equal "Video 'cam': start must be a number of seconds, at least 0.",
                 refused { |dn| decide_video(dn, DecisionNode::Video.new("cam", frames: frames(0), start: -1)) }
    assert_equal "Video 'cam': end must be after start.",
                 refused { |dn| decide_video(dn, DecisionNode::Video.new("cam", frames: frames(0), start: 3, end: 1)) }
    assert_equal "Video 'cam': end must be after start.",
                 refused { |dn| decide_video(dn, DecisionNode::Video.new("cam", frames: frames(0), end: 0)) }
    assert_equal "Video \"it's\": end must be after start.",
                 refused { |dn| decide_video(dn, DecisionNode::Video.new("it's", frames: frames(0), end: 0)) }
  end

  def test_left_to_the_server
    http = FakeHTTP.new(FakeHTTP.json(200, truth_body))
    dn = client(http)
    # A frame's bytes against its declared type, and the frame count, are the server's.
    decide_video(dn, DecisionNode::Video.new("cam", frames: [DecisionNode::Frame.new(0, data: jpeg, media_type: "image/png")]))
    decide_video(dn, DecisionNode::Video.new("cam", frames: frames(*Array.new(200) { |i| i * 0.5 })))
    assert_equal 2, http.calls.size
  end

  def test_argument_errors
    assert_raises(ArgumentError) { DecisionNode::Frame.new("1", data: jpeg) }
    assert_raises(ArgumentError) { DecisionNode::Frame.new(1, data: jpeg, base64: "x") }
    assert_raises(ArgumentError) { DecisionNode::Frame.new(1, path: "/no/such/frame.jpg") }
    assert_raises(ArgumentError) { DecisionNode::Video.new("cam", frames: "x") }
    assert_raises(ArgumentError) { DecisionNode::Video.new("cam", frames: ["x"]) }
    assert_raises(ArgumentError) { DecisionNode::Video.new("cam", frames: frames(0), fps: "2") }
    dn = client(FakeHTTP.new(FakeHTTP.json(200, truth_body)))
    assert_raises(ArgumentError) { dn.decide(questions: { "q" => DecisionNode.truth("?") }, videos: "x") }
    assert_raises(ArgumentError) { dn.decide(questions: { "q" => DecisionNode.truth("?") }, videos: ["x"]) }
  end

  def test_decision_video_fields
    body = truth_body.merge("usage" => { "input_tokens" => 9120, "output_tokens" => 0, "video_frames" => 250, "video_seconds" => 1.4999999999999998 },
                            "warnings" => ["Video 'dock' was read at 0.4 frames a second."])
    d = DecisionNode::Decision.new(body)
    assert_equal 250, d.usage.video_frames
    assert_equal 1.4999999999999998, d.usage.video_seconds
    assert_equal ["Video 'dock' was read at 0.4 frames a second."], d.warnings
    plain = DecisionNode::Decision.new(truth_body)
    assert_nil plain.usage.video_frames
    assert_nil plain.usage.video_seconds
    assert_equal [], plain.warnings
  end
end
