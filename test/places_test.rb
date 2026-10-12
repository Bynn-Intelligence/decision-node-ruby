# frozen_string_literal: true

require_relative "test_helper"

# Several places in one answer: max on a point or box question, the
# PointsAnswer and BoxesAnswer it is answered with, the local checks of max
# and the capability a held /v1/models entry states.
class PlacesTest < Minitest::Test
  include ClientHelpers

  LOT = DecisionNode::Image.new("lot", url: "https://files.example.com/lot/0917.jpg")

  def boxes_body
    { "model" => "decisionnode-moe-0.9.0-rc1",
      "answers" => { "cars" => { "type" => "box", "count" => 2, "present" => 0.99, "complete" => 0.94,
                                 "boxes" => [{ "x1" => 112, "y1" => 400, "x2" => 388, "y2" => 590, "confidence" => 0.91 },
                                             { "x1" => 402, "y1" => 395, "x2" => 660, "y2" => 598, "confidence" => 0.9 }],
                                 "image" => "lot", "width" => 1920, "height" => 1080 } },
      "usage" => { "input_tokens" => 1350, "output_tokens" => 0 } }
  end

  def models_body(places)
    entry = { "name" => "decisionnode-moe", "version" => "decisionnode-moe-0.9.0-rc1", "alias" => "decisionnode-moe" }
    entry["places"] = places unless places.nil?
    { "models" => [entry] }
  end

  def test_builders_send_max_only_when_given
    assert_equal({ "type" => "box", "instructions" => "Every car in the lot.", "image" => "lot", "max" => 8 },
                 DecisionNode.box("Every car in the lot.", image: "lot", max: 8))
    assert_equal({ "type" => "point", "instructions" => "Each person.", "max" => 6 }, DecisionNode.point("Each person.", max: 6))
    refute DecisionNode.point("Where?").key?("max")
    http = FakeHTTP.new(FakeHTTP.json(200, boxes_body))
    client(http).decide(images: [LOT], questions: { "cars" => DecisionNode.box("Every car in the lot.", max: 8) })
    assert_equal 8, http.calls.first.json["questions"]["cars"]["max"]
  end

  def test_boxes_and_points_answers
    d = DecisionNode::Decision.new(boxes_body)
    cars = d["cars"]
    assert_instance_of DecisionNode::BoxesAnswer, cars
    assert_equal [2, 0.99, 0.94, "lot", 1920, 1080], [cars.count, cars.present, cars.complete, cars.image, cars.width, cars.height]
    assert_equal [[112, 400, 388, 590, 0.91], [402, 395, 660, 598, 0.9]], cars.boxes.map(&:to_a)
    people = DecisionNode::Answer.from("type" => "point", "count" => 1, "present" => 0.97, "complete" => 0.99,
                                       "points" => [{ "x" => 0.3333, "y" => 0.4741, "confidence" => 0.88 }],
                                       "image" => "platform", "width" => 1920, "height" => 1080)
    assert_instance_of DecisionNode::PointsAnswer, people
    # Normalized fractions are kept as sent.
    assert_equal [0.3333, 0.4741, 0.88], people.points.first.to_a
    none = DecisionNode::Answer.from("type" => "box", "count" => 0, "present" => 0.02, "complete" => 0.99, "boxes" => [],
                                     "image" => "lot", "width" => 1920, "height" => 1080)
    assert_instance_of DecisionNode::BoxesAnswer, none
    assert_equal [0, []], [none.count, none.boxes]
  end

  def test_a_malformed_places_answer_is_unknown
    base = { "type" => "box", "count" => 1, "present" => 0.9, "complete" => 0.9,
             "boxes" => [{ "x1" => 1, "y1" => 2, "x2" => 3, "y2" => 4, "confidence" => 0.5 }],
             "image" => "lot", "width" => 1920, "height" => 1080 }
    assert_instance_of DecisionNode::BoxesAnswer, DecisionNode::Answer.from(base)
    [
      base.merge("count" => "3"),
      base.merge("count" => 1.0),
      base.merge("boxes" => [{ "x1" => 1, "y1" => 2, "x2" => 3, "y2" => 4 }]),
      base.merge("boxes" => [{ "x1" => true, "y1" => 2, "x2" => 3, "y2" => 4, "confidence" => 0.5 }]),
      base.except("complete"),
      base.merge("boxes" => { "x1" => 1 }),
      base.except("boxes").merge("points" => [{ "x" => 1, "y" => 2, "confidence" => 0.5 }]),
      base.merge("present" => true)
    ].each do |raw|
      assert_instance_of DecisionNode::UnknownAnswer, DecisionNode::Answer.from(raw), raw.inspect
    end
  end

  def test_local_checks_of_max
    dn = client(FakeHTTP.new(FakeHTTP.json(200, boxes_body)))
    [[2.5, "int_type", "Input should be a valid integer", nil],
     ["8", "int_type", "Input should be a valid integer", nil],
     [true, "int_type", "Input should be a valid integer", nil],
     [1, "greater_than_equal", "Input should be greater than or equal to 2", { "ge" => 2 }],
     [17, "less_than_equal", "Input should be less than or equal to 16", { "le" => 16 }]].each do |most, type, msg, ctx|
      error = assert_raises(DecisionNode::ValidationError) do
        dn.check_request("decide", images: [LOT], questions: { "cars" => DecisionNode.box("Every car.", max: most) })
      end
      expected = { "type" => type, "loc" => %w[body questions cars box max], "msg" => msg, "input" => most }
      expected["ctx"] = ctx if ctx
      assert_equal [expected], error.entries
      assert_nil error.status
    end
    assert_nil dn.check_request("decide", images: [LOT], questions: { "cars" => DecisionNode.box("Every car.", max: 2) })
    assert_nil dn.check_request("decide", images: [LOT], questions: { "cars" => DecisionNode.box("Every car.", max: 16) })
  end

  def test_max_is_checked_in_decide_many_and_batch_lines
    http = FakeHTTP.new(FakeHTTP.json(200, boxes_body))
    dn = client(http)
    bad = { images: [LOT], questions: { "cars" => DecisionNode.box("Every car.", max: 17) } }
    assert_raises(DecisionNode::ValidationError) { dn.decide_many([{ images: [LOT], questions: { "q" => DecisionNode.truth("?") } }, bad]) }
    assert_raises(DecisionNode::ValidationError) { dn.check_request("batches.create", requests: [bad.merge(custom_id: "c1")]) }
    assert_empty http.calls
  end

  # Whether a model answers several places is the server's to say: a held
  # models entry with or without places.max_places never refuses max locally.
  def test_max_is_sent_whatever_the_held_models_entry_says
    [nil, {}, { "max_places" => 0 }, { "max_places" => 16 }].each do |places|
      http = FakeHTTP.new(FakeHTTP.json(200, models_body(places)), FakeHTTP.json(200, boxes_body))
      dn = client(http)
      dn.models
      answer = dn.decide(images: [LOT], questions: { "cars" => DecisionNode.box("Every car.", max: 8) })["cars"]
      assert_instance_of DecisionNode::BoxesAnswer, answer
      assert_equal 8, http.calls.last.json.dig("questions", "cars", "max")
      assert_nil dn.check_request("decide", images: [LOT], questions: { "cars" => DecisionNode.box("Every car.", max: 8) })
    end
    assert_nil client(FakeHTTP.new).check_request("decide", images: [LOT], questions: { "cars" => DecisionNode.box("Every car.", max: 8) })
  end
end
