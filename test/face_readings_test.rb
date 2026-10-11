# frozen_string_literal: true

require "test_helper"

# The face_detection and wanted_person readings: typed when every field is
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

  def test_wanted_person_reading
    results = evidence("wanted_person", [
                         { "image" => "door", "faces" => 2,
                           "matches" => [{ "box" => box(5, 6, 50, 60), "score" => 0.87, "reference" => "ref_0042" }] },
                         { "image" => "hall", "faces" => 3, "matches" => [] }
                       ])
    door, hall = results
    assert_instance_of DecisionNode::WantedPersonReading, door
    match = door.matches.first
    assert_equal [2, DecisionNode::FaceBox.new(5, 6, 50, 60), 0.87, "ref_0042"],
                 [door.faces, match.box, match.score, match.reference]
    assert_instance_of DecisionNode::WantedPersonReading, hall
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

  def test_malformed_wanted_person_is_generic
    malformed = [
      { "image" => "a", "faces" => 1 },
      { "image" => "a", "faces" => 1, "matches" => [{ "box" => box(1, 2, 3, 4), "score" => 0.5 }] },
      { "image" => "a", "faces" => 1, "matches" => [{ "box" => box(1, 2, 3, 4), "score" => 0.5, "reference" => 42 }] },
      { "image" => "a", "faces" => 1, "matches" => [{ "box" => box(1, 2, 3, 4), "reference" => "r" }] },
      { "image" => "a", "faces" => 1, "matches" => [{ "score" => 0.5, "reference" => "r" }] },
      { "image" => "a", "faces" => "1", "matches" => [] }
    ]
    evidence("wanted_person", malformed).each { |r| assert_instance_of DecisionNode::UnknownReading, r }
  end
end
