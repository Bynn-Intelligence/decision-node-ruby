# frozen_string_literal: true

require_relative "test_helper"

# check_request and Session#check_frame run the checks of sending alone;
# held /v1/models limits are found by name, alias or pinned version.
class CheckRequestTest < Minitest::Test
  include ClientHelpers

  FIXTURES = File.join(__dir__, "fixtures", "images")

  def questions
    { "q" => DecisionNode.truth("Escalate?") }
  end

  def test_a_clean_request_returns_nil_and_sends_nothing
    http = FakeHTTP.new(FakeHTTP.json(200, truth_body))
    dn = client(http, inline_threshold: 0) # sending would upload the image
    image = DecisionNode::Image.new("a", data: File.binread(File.join(FIXTURES, "image.png")))
    assert_nil dn.check_request("decide", state: "s", questions: questions, images: [image])
    assert_nil dn.check_request(:decide, { state: "s", questions: questions })
    assert_raises(ArgumentError) { dn.check_request("systemone", state: "s", questions: questions) }
    assert_nil dn.check_request("open_session", "questions" => questions, "window" => 4)
    assert_nil dn.check_request("batches.create", requests: [])
    assert_nil dn.check_request("batches.add", batch_id: "batch_01J9ZB8Q3T",
                                               requests: [{ custom_id: "a", state: "s", questions: questions }])
    assert_empty http.calls
  end

  def test_a_fault_raises_what_sending_raises
    http = FakeHTTP.new(FakeHTTP.json(200, truth_body))
    dn = client(http)
    bad = { "q" => DecisionNode.choice("?", (0..255).map(&:to_s)) }
    sent = assert_raises(DecisionNode::BadRequestError) { dn.decide(state: "s", questions: bad) }
    checked = assert_raises(DecisionNode::BadRequestError) { dn.check_request("decide", state: "s", questions: bad) }
    assert_equal [sent.message, sent.error_type], [checked.message, checked.error_type]

    error = assert_raises(DecisionNode::ValidationError) do
      dn.check_request("open_session", questions: questions, window: 65)
    end
    assert_equal "less_than_equal", error.entries.first["type"]
    error = assert_raises(DecisionNode::BadRequestError) do
      dn.check_request("batches.add", batch_id: "x", requests: [{ custom_id: "a", questions: questions }] * 2)
    end
    assert_equal 'Line 2: custom_id "a" is already in the batch.', error.message
    assert_raises(DecisionNode::BadRequestError) { dn.check_request("batches.add", requests: []) }
    assert_raises(ArgumentError) { dn.check_request("decide", state: "s", questions: {}) }
    assert_raises(ArgumentError) { dn.check_request("models") }
    assert_raises(ArgumentError) { dn.check_request("decide", colour: "red", questions: questions) }
    assert_empty http.calls
  end

  def test_check_frame_needs_no_socket_and_uses_no_seq
    s = DecisionNode::Session.new(client(FakeHTTP.new), { "session_id" => "ses_1", "model" => "decisionnode-1.0",
                                                          "questions" => %w[mode abort] })
    assert_nil s.check_frame(frame: { battery: 0.3 }, questions: ["abort"])
    error = assert_raises(DecisionNode::BadRequestError) { s.check_frame(frame: "a", questions: ["speed"]) }
    assert_equal ["questions: unknown question id 'speed'", "api_usage_error"], [error.message, error.error_type]
    assert_raises(DecisionNode::BadRequestError) { s.check_frame }
    assert_raises(DecisionNode::BadRequestError) { s.check_frame(frame: "") }
    assert_raises(DecisionNode::BadRequestError) { s.check_frame(frame: "a", seq: -1) }
    assert_raises(DecisionNode::BadRequestError) do
      s.check_frame(image: DecisionNode::Image.new("i", url: "https://example.com/i.png"))
    end
  end

  # A frame's image is sent without its id, so the 64-character id rule does not apply.
  def test_check_frame_does_not_check_the_image_id_length
    s = DecisionNode::Session.new(client(FakeHTTP.new), { "session_id" => "ses_1", "model" => "decisionnode-1.0",
                                                          "questions" => %w[abort] })
    png = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==".unpack1("m")
    assert_nil s.check_frame(image: DecisionNode::Image.new("f" * 65, data: png))
  end

  def models_body
    { "models" => [
      { "name" => "decisionnode-1.0", "version" => "decisionnode-1.0", "alias" => "decisionnode-latest",
        "number_max_grid_values" => 0, "sessions" => { "enabled" => true, "max_window" => 8 } },
      { "name" => "decisionnode-1.0-flash", "version" => "decisionnode-1.0-flash", "alias" => "decisionnode-flash-latest" }
    ] }
  end

  def test_held_limits_are_found_by_alias_or_version
    http = FakeHTTP.new(FakeHTTP.json(200, models_body))
    dn = client(http) # the client's model is decisionnode-latest
    dn.models
    error = assert_raises(DecisionNode::BadRequestError) do
      dn.check_request("decide", state: "s", questions: { "n" => DecisionNode.number("How many?") })
    end
    assert_equal "Model decisionnode-latest does not answer number questions.", error.message
    error = assert_raises(DecisionNode::ValidationError) { dn.check_request("open_session", questions: questions, window: 9) }
    assert_equal({ "le" => 8 }, error.entries.first["ctx"])
    # The flash model states neither limit, and a name the list does not state holds nothing.
    assert_nil dn.check_request("decide", questions: { "n" => DecisionNode.number("n") }, model: "decisionnode-flash-latest")
    assert_nil dn.check_request("open_session", questions: questions, window: 64, model: "decisionnode-2.0")
  end
end
