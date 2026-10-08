# frozen_string_literal: true

require_relative "test_helper"

# Point and box questions: the builders, the answers and the local checks.
class PointBoxTest < Minitest::Test
  include ClientHelpers

  BELT = DecisionNode::Image.new("belt", url: "https://files.example.com/line-3/cam-2/0917.jpg")
  DOCK = DecisionNode::Image.new("dock", url: "https://files.example.com/dock/0001.jpg")

  def test_builders
    assert_equal({ "type" => "point", "instructions" => "Where?" }, DecisionNode.point("Where?"))
    assert_equal({ "type" => "box", "instructions" => "Where?", "image" => "belt", "units" => "normalized" },
                 DecisionNode.box("Where?", image: "belt", units: "normalized"))
  end

  def test_answers
    d = DecisionNode::Decision.new(
      "answers" => {
        "pick" => { "type" => "point", "x" => 812, "y" => 455, "present" => 0.97, "confidence" => 0.91,
                    "image" => "belt", "width" => 1920, "height" => 1080 },
        "damage" => { "type" => "box", "x1" => 0.1562, "y1" => 0.1111, "x2" => 0.2708, "y2" => 0.3796, "present" => 0.95,
                      "confidence" => 0.88, "image" => "belt", "width" => 1920, "height" => 1080 },
        "bad" => { "type" => "point", "x" => true, "y" => 455, "present" => 0.97, "confidence" => 0.91,
                   "image" => "belt", "width" => 1920, "height" => 1080 }
      }
    )
    assert_kind_of DecisionNode::PointAnswer, d["pick"]
    assert_equal [812, 455, 0.97, 0.91, "belt", 1920, 1080],
                 [d["pick"].x, d["pick"].y, d["pick"].present, d["pick"].confidence, d["pick"].image, d["pick"].width, d["pick"].height]
    assert_kind_of DecisionNode::BoxAnswer, d["damage"]
    assert_equal [0.1562, 0.1111, 0.2708, 0.3796], [d["damage"].x1, d["damage"].y1, d["damage"].x2, d["damage"].y2]
    assert_kind_of DecisionNode::UnknownAnswer, d["bad"]
  end

  def test_sent_with_an_image
    http = FakeHTTP.new(FakeHTTP.json(200, truth_body))
    client(http).decide(images: [BELT], questions: { "pick" => DecisionNode.point("Point to the yellow package.") })
    assert_equal({ "type" => "point", "instructions" => "Point to the yellow package." }, http.calls.first.json["questions"]["pick"])
  end

  def test_local_checks_list_every_entry
    dn = client(FakeHTTP.new(FakeHTTP.json(200, truth_body)))
    error = assert_raises(DecisionNode::ValidationError) do
      dn.decide(images: [BELT, DOCK], videos: [DecisionNode::Video.new("cam", frames: [DecisionNode::VideoFrame.new(0, base64: "AA==", media_type: "image/jpeg")])],
                questions: { "pick" => DecisionNode.point("Where?", image: "cam", units: "inches"),
                             "damage" => DecisionNode.box("Where?"),
                             "odd" => DecisionNode.box("Where?", image: 3) })
    end
    assert_nil error.status
    assert_equal [%w[unknown_image image], %w[literal_error units], %w[missing image], %w[string_type image]],
                 error.entries.map { |e| [e["type"], e["loc"].last] }
    assert_equal({ "expected" => "'pixels' or 'normalized'" }, error.entries[1]["ctx"])
    none = assert_raises(DecisionNode::ValidationError) { dn.decide(questions: { "pick" => DecisionNode.point("Where?") }) }
    assert_equal [{ "type" => "image_required", "loc" => %w[body questions pick point], "msg" => "A point question needs an image in the request",
                    "input" => { "type" => "point", "instructions" => "Where?" } }], none.entries
    bare = assert_raises(DecisionNode::BadRequestError) { dn.decide(images: [BELT], questions: { "pick" => DecisionNode.box }) }
    assert_equal "Box question must have instructions: pick", bare.message
    assert_nil bare.error_type
    refute_respond_to dn, :systemone
    assert_nil dn.check_request("open_session", questions: { "pick" => DecisionNode.point("Where?") })
  end
end
