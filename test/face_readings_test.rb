# frozen_string_literal: true

require "test_helper"

# The face_detection and face_recognition readings: typed when every field is
# present and of the right type, generic otherwise.
class FaceReadingsTest < Minitest::Test
  include ClientHelpers

  Q = { "q" => DecisionNode.truth("?") }.freeze

  def box(x1, y1, x2, y2)
    { "x1" => x1, "y1" => y1, "x2" => x2, "y2" => y2 }
  end

  def evidence(booster, results)
    body = truth_body.merge("evidence" => { booster => { "status" => "ok", "results" => results } })
    client(FakeHTTP.new(FakeHTTP.json(200, body))).decide(questions: Q).evidence[booster].results
  end

  def test_face_detection_reading
    results = evidence("face_detection", [
                         { "image" => "crowd", "faces" => 70,
                           "detections" => [{ "box" => box(10, 20, 110, 140), "confidence" => 0.98 },
                                            { "box" => box(300, 40, 380, 150), "confidence" => 0.91 }] },
                         { "image" => "empty", "faces" => 0, "detections" => [] }
                       ])
    crowd, empty = results
    assert_instance_of DecisionNode::FaceDetectionReading, crowd
    # faces counts every face found; the list holds at most 64 of them.
    assert_equal ["crowd", 70, 2], [crowd.image, crowd.faces, crowd.detections.size]
    first = crowd.detections.first
    assert_equal DecisionNode::FaceBox.new(10, 20, 110, 140), first.box
    assert_in_delta 0.98, first.confidence
    assert_instance_of DecisionNode::FaceDetectionReading, empty
    assert_empty empty.detections
  end

  def test_normalized_corners_are_kept_as_sent
    results = evidence("face_detection", [
                         { "image" => "a", "faces" => 1,
                           "detections" => [{ "box" => box(0.1234, 0.2, 0.5678, 0.9), "confidence" => 0.9 }] }
                       ])
    assert_equal [0.1234, 0.2, 0.5678, 0.9], results.first.detections.first.box.to_a
  end

  def test_face_recognition_reading
    results = evidence("face_recognition", [
                         { "image" => "door", "faces" => 2,
                           "matches" => [
                             { "box" => box(5, 6, 50, 60), "score" => 0.87, "collection" => "col_1", "reference" => "emp-0042",
                               "label" => "Reception" },
                             { "box" => box(70, 6, 120, 60), "score" => 0.81, "collection" => "celebrities",
                               "reference" => "pub-1", "name" => "A Public Figure" }
                           ] },
                         { "image" => "hall", "faces" => 3, "matches" => [] }
                       ])
    door, hall = results
    assert_instance_of DecisionNode::FaceRecognitionReading, door
    own, public_figure = door.matches
    assert_equal [2, DecisionNode::FaceBox.new(5, 6, 50, 60), 0.87, "col_1", "emp-0042", nil, "Reception"],
                 [door.faces, own.box, own.score, own.collection, own.reference, own.name, own.label]
    assert_equal ["celebrities", "pub-1", "A Public Figure", nil],
                 [public_figure.collection, public_figure.reference, public_figure.name, public_figure.label]
    assert_instance_of DecisionNode::FaceRecognitionReading, hall
    assert_empty hall.matches
  end

  def test_malformed_face_detection_is_generic
    good = { "box" => box(1, 2, 3, 4), "confidence" => 0.5 }
    malformed = [
      { "image" => "a", "faces" => 1.5, "detections" => [good] },
      { "image" => "a", "faces" => -1, "detections" => [good] },
      { "image" => "a", "faces" => 1 },
      { "image" => "a", "faces" => 1, "detections" => good },
      { "image" => "a", "faces" => 1, "detections" => ["x"] },
      { "image" => "a", "faces" => 1, "detections" => [{ "box" => { "x1" => 1, "y1" => 2, "x2" => 3 }, "confidence" => 0.5 }] },
      { "image" => "a", "faces" => 1, "detections" => [{ "box" => box(1, 2, 3, "4"), "confidence" => 0.5 }] },
      { "image" => "a", "faces" => 1, "detections" => [{ "box" => box(1, 2, 3, 4) }] },
      { "image" => "a", "faces" => 1, "detections" => [{ "box" => box(1, 2, 3, 4), "confidence" => "high" }] },
      { "image" => 7, "faces" => 1, "detections" => [good] }
    ]
    results = evidence("face_detection", malformed)
    results.each { |r| assert_instance_of DecisionNode::UnknownReading, r }
    assert_equal malformed, results.map(&:raw)
  end

  def test_malformed_face_recognition_is_generic
    good = { "box" => box(1, 2, 3, 4), "score" => 0.5, "collection" => "c", "reference" => "r" }
    malformed = [
      { "image" => "a", "faces" => 1 },
      { "matches" => [good], "image" => "a" },
      { "image" => "a", "faces" => 1, "matches" => [good.reject { |k, _| k == "collection" }] },
      { "image" => "a", "faces" => 1, "matches" => [good.merge("collection" => 7)] },
      { "image" => "a", "faces" => 1, "matches" => [good.reject { |k, _| k == "reference" }] },
      { "image" => "a", "faces" => 1, "matches" => [good.merge("reference" => 42)] },
      { "image" => "a", "faces" => 1, "matches" => [good.merge("name" => 1)] },
      { "image" => "a", "faces" => 1, "matches" => [good.merge("label" => false)] },
      { "image" => "a", "faces" => 1, "matches" => [good.reject { |k, _| k == "score" }] },
      { "image" => "a", "faces" => 1, "matches" => [good.reject { |k, _| k == "box" }] },
      { "image" => "a", "faces" => "1", "matches" => [] }
    ]
    evidence("face_recognition", malformed).each { |r| assert_instance_of DecisionNode::UnknownReading, r }
    # A name or label sent as null is absent, and the reading stays typed.
    typed = evidence("face_recognition", [{ "image" => "a", "faces" => 1, "matches" => [good.merge("name" => nil, "label" => nil)] }])
    assert_instance_of DecisionNode::FaceRecognitionReading, typed.first
  end
end
