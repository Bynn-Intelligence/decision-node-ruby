# frozen_string_literal: true

require "test_helper"

# The bynn_depth (Depth Vision) and bynn_segment (Segment Vision) readings:
# typed when every field is present and of the right type, generic
# otherwise; and their options sent as given.
class VisionReadingsTest < Minitest::Test
  include ClientHelpers

  Q = { "q" => DecisionNode.truth("?") }.freeze

  DEPTH = {
    "image" => "front", "ahead" => 3.21, "directions" => [5.12, 4.03, nil, 2.81, 6.02, 7.15, 9.33],
    "ground" => true, "grid_rows" => 2, "grid_cols" => 2, "grid" => [[10.1, 10.2], [3.4, 2.05]],
    "depth_min" => 2.05, "depth_max" => 14.98, "depth_median" => 4.37, "width" => 810, "height" => 1080
  }.freeze

  GATE = {
    "label" => "purple octagonal frame on a pole", "score" => 0.812, "box" => [0.31, 0.2, 0.69, 0.85],
    "polygon" => [[0.31, 0.2], [0.69, 0.2], [0.69, 0.85], [0.31, 0.85]], "area" => 0.10512,
    "centroid" => [0.5004, 0.5251],
    "opening" => { "polygon" => [[0.36, 0.3], [0.64, 0.3], [0.64, 0.75], [0.36, 0.75]], "centroid" => [0.5, 0.525],
                   "width" => 0.28, "height" => 0.45, "offset" => [0.0, 0.0], "area" => 0.126 },
    "depth" => { "median" => 5.05, "opening_median" => 10.5, "opening_rim_median" => 5.1 },
    "size_m" => { "width" => 2.45, "height" => 2.33, "opening" => { "width" => 1.82, "height" => 1.63 } }
  }.freeze

  PAD = {
    "label" => "landing pad", "score" => 0.37, "box" => [0.4, 0.6, 0.6, 0.9],
    "polygon" => [[0.4, 0.6], [0.6, 0.6], [0.6, 0.9]], "area" => 0.04, "centroid" => [0.5, 0.75], "opening" => nil,
    "depth" => { "median" => 7.2, "opening_median" => nil, "opening_rim_median" => nil },
    "size_m" => { "width" => 1.2, "height" => 1.1, "opening" => nil }
  }.freeze

  SEGMENT = {
    "image" => "front", "width" => 1280, "height" => 720,
    "prompts" => ["purple octagonal frame on a pole", "landing pad"], "instances" => [GATE, PAD],
    "depth_source" => "bynn_depth", "assumed_hfov_deg" => 65.0
  }.freeze

  def evidence(booster, results)
    body = truth_body.merge("evidence" => { booster => { "status" => "ok", "results" => results } })
    client(FakeHTTP.new(FakeHTTP.json(200, body))).decide(questions: Q).evidence[booster].results
  end

  # A deep copy of base with the value at path replaced, or removed when
  # value is :remove.
  def changed(base, path, value)
    out = Marshal.load(Marshal.dump(base))
    node = path[0...-1].reduce(out) { |n, k| n[k] }
    value == :remove ? node.delete(path.last) : node[path.last] = value
    out
  end

  # ---- bynn_depth

  def test_depth_reading
    reading, = evidence("bynn_depth", [DEPTH])
    assert_instance_of DecisionNode::DepthReading, reading
    assert_equal ["front", 3.21, true], [reading.image, reading.ahead, reading.ground]
    assert_equal [5.12, 4.03, nil, 2.81, 6.02, 7.15, 9.33], reading.directions
    assert_equal [2, 2, [[10.1, 10.2], [3.4, 2.05]]], [reading.grid_rows, reading.grid_cols, reading.grid]
    assert_equal [2.05, 14.98, 4.37], [reading.depth_min, reading.depth_max, reading.depth_median]
    assert_equal [810, 1080], [reading.width, reading.height]
    assert_equal DEPTH, reading.raw
  end

  def test_depth_with_nothing_ahead_is_a_reading
    reading, = evidence("bynn_depth", [changed(changed(DEPTH, ["ahead"], nil), ["directions"], [nil] * 7)])
    assert_instance_of DecisionNode::DepthReading, reading
    assert_nil reading.ahead
    assert_equal [nil] * 7, reading.directions
  end

  def test_an_unreadable_picture_is_generic
    reading, = evidence("bynn_depth", [{ "image" => "front", "readable" => false }])
    assert_instance_of DecisionNode::UnknownReading, reading
    assert_equal "front", reading.image
    assert_equal({ "image" => "front", "readable" => false }, reading.raw)
  end

  def test_depth_without_ahead_reads_nil
    reading, = evidence("bynn_depth", [changed(DEPTH, ["ahead"], :remove)])
    assert_instance_of DecisionNode::DepthReading, reading
    assert_nil reading.ahead
  end

  def test_malformed_depth_is_generic
    [
      [["ahead"], "near"], [["directions"], "left"], [["directions"], [1.0] * 6], [["directions"], [1.0] * 8],
      [["directions", 0], "far"],
      [["ground"], 1], [["grid_rows"], 2.5], [["grid"], [[1.0, "x"]]], [["grid"], [1.0, 2.0]],
      [["depth_median"], nil], [["width"], "810"], [["image"], 3]
    ].each do |path, value|
      raw = changed(DEPTH, path, value)
      reading, = evidence("bynn_depth", [raw])
      assert_instance_of DecisionNode::UnknownReading, reading, path.inspect
      assert_equal raw, reading.raw
    end
  end

  # ---- bynn_segment

  def test_segment_reading
    reading, = evidence("bynn_segment", [SEGMENT])
    assert_instance_of DecisionNode::SegmentReading, reading
    assert_equal ["front", 1280, 720, SEGMENT["prompts"]], [reading.image, reading.width, reading.height, reading.prompts]
    assert_equal ["bynn_depth", 65.0], [reading.depth_source, reading.assumed_hfov_deg]
    gate, pad = reading.instances
    expected = DecisionNode::SegmentInstance.new(
      "purple octagonal frame on a pole", 0.812, [0.31, 0.2, 0.69, 0.85],
      [[0.31, 0.2], [0.69, 0.2], [0.69, 0.85], [0.31, 0.85]], 0.10512, [0.5004, 0.5251],
      DecisionNode::SegmentOpening.new([[0.36, 0.3], [0.64, 0.3], [0.64, 0.75], [0.36, 0.75]], [0.5, 0.525], 0.28, 0.45,
                                       [0.0, 0.0], 0.126),
      DecisionNode::SegmentDepth.new(5.05, 10.5, 5.1),
      DecisionNode::SegmentSize.new(2.45, 2.33, DecisionNode::SegmentExtent.new(1.82, 1.63))
    )
    assert_equal expected, gate
    assert_nil pad.opening
    assert_equal DecisionNode::SegmentSize.new(1.2, 1.1, nil), pad.size_m
    assert_equal DecisionNode::SegmentDepth.new(7.2, nil, nil), pad.depth
  end

  def test_segment_without_depth_or_instances_is_a_reading
    no_depth = GATE.merge("depth" => nil, "size_m" => nil)
    reading, = evidence("bynn_segment", [SEGMENT.merge("instances" => [no_depth], "depth_source" => nil)])
    assert_instance_of DecisionNode::SegmentReading, reading
    assert_nil reading.depth_source
    assert_nil reading.instances.first.depth
    assert_nil reading.instances.first.size_m
    empty, = evidence("bynn_segment", [SEGMENT.merge("instances" => [])])
    assert_instance_of DecisionNode::SegmentReading, empty
    assert_empty empty.instances
  end

  def test_segment_fields_absent_read_as_nil
    {
      ["depth_source"] => ->(r) { r.depth_source },
      ["assumed_hfov_deg"] => ->(r) { r.assumed_hfov_deg },
      ["instances", 0, "opening"] => ->(r) { r.instances.first.opening },
      ["instances", 0, "depth"] => ->(r) { r.instances.first.depth },
      ["instances", 0, "depth", "opening_median"] => ->(r) { r.instances.first.depth.opening_median },
      ["instances", 0, "size_m"] => ->(r) { r.instances.first.size_m },
      ["instances", 0, "size_m", "opening"] => ->(r) { r.instances.first.size_m.opening }
    }.each do |path, read|
      reading, = evidence("bynn_segment", [changed(SEGMENT, path, :remove)])
      assert_instance_of DecisionNode::SegmentReading, reading, path.inspect
      assert_nil read.call(reading), path.inspect
    end
  end

  def test_malformed_segment_is_generic
    [
      [["prompts"], "gate"], [["prompts", 0], 7], [["instances"], { "label" => "gate" }], [["depth_source"], 5],
      [["assumed_hfov_deg"], "wide"], [["width"], 1280.5], [["instances", 0, "label"], nil],
      [["instances", 0, "box"], [0.1, 0.2, 0.3]], [["instances", 0, "polygon"], [[0.1, 0.2, 0.3]]],
      [["instances", 0, "centroid"], { "x" => 0.5, "y" => 0.5 }], [["instances", 0, "opening"], "hole"],
      [["instances", 0, "opening", "offset"], [0.0]], [["instances", 0, "opening", "area"], :remove],
      [["instances", 0, "depth"], 5.05], [["instances", 0, "depth", "opening_median"], "far"],
      [["instances", 0, "size_m"], [2.45, 2.33]], [["instances", 0, "size_m", "width"], :remove],
      [["instances", 0, "size_m", "opening"], 1.82], [["instances", 0, "size_m", "opening", "width"], nil]
    ].each do |path, value|
      raw = changed(SEGMENT, path, value)
      reading, = evidence("bynn_segment", [raw])
      assert_instance_of DecisionNode::UnknownReading, reading, path.inspect
      assert_equal raw, reading.raw
    end
  end

  # ---- options

  def test_options_are_sent_as_given
    http = FakeHTTP.new(FakeHTTP.json(200, truth_body))
    client(http).decide(state: "s", questions: Q, boosters: [
                          DecisionNode::Booster.new("bynn_depth", options: { "grid_size" => 16 }),
                          DecisionNode::Booster.new("bynn_segment", options: { "prompt" => ["landing pad", "person"], "depth" => false })
                        ])
    assert_equal [{ "name" => "bynn_depth", "options" => { "grid_size" => 16 } },
                  { "name" => "bynn_segment", "options" => { "prompt" => ["landing pad", "person"], "depth" => false } }],
                 http.calls.first.json["boosters"]
  end
end
