# frozen_string_literal: true

require "test_helper"

# Boosters on the request, evidence and booster usage in the response, the
# boosters header on errors, and fine-tuned models.
class BoostersTest < Minitest::Test
  include ClientHelpers

  Q = { "q" => DecisionNode.truth("?") }.freeze
  IMAGES = [DecisionNode::Image.new("a1b2", url: "https://example.com/a1b2.jpg"),
            DecisionNode::Image.new("c3d4", url: "https://example.com/c3d4.jpg")].freeze

  def ok
    FakeHTTP.json(200, truth_body)
  end

  # ---- the request

  def test_booster_wire_forms
    assert_equal({ "booster" => "age" }, DecisionNode::Booster.new("age").to_h)
    assert_equal({ "booster" => "age" }, DecisionNode::Booster.new(:age).to_h)
    assert_equal({ "booster" => "ai_generated", "images" => ["c3d4"], "require" => true, "options" => { "k" => 1 } },
                 DecisionNode::Booster.new("ai_generated", images: ["c3d4"], require: true, options: { "k" => 1 }).to_h)
    assert_equal({ "booster" => "age", "require" => false }, DecisionNode::Booster.new("age", require: false).to_h)
  end

  def test_boosters_are_sent_in_order_after_the_other_fields
    http = FakeHTTP.new(ok)
    client(http).decide(state: "s", questions: Q, images: IMAGES,
                        boosters: ["age", DecisionNode::Booster.new("ai_generated", images: ["c3d4"], require: true),
                                   { "booster" => "other", "options" => {} }])
    body = http.calls.first.json
    assert_equal %w[model state questions images boosters], body.keys
    assert_equal ["age", { "booster" => "ai_generated", "images" => ["c3d4"], "require" => true },
                  { "booster" => "other", "options" => {} }], body["boosters"]
  end

  def test_no_boosters_key_when_left_out_or_empty
    [nil, []].each do |boosters|
      http = FakeHTTP.new(ok)
      client(http).decide(state: "s", questions: Q, boosters: boosters)
      refute http.calls.first.json.key?("boosters"), boosters.inspect
      assert_equal JSON.generate({ "model" => "decisionnode-latest", "state" => "s", "questions" => Q }), http.calls.first.body
    end
  end

  def test_a_booster_outside_a_list_is_sent_in_its_wire_form
    http = FakeHTTP.new(ok)
    client(http).decide(questions: Q, boosters: DecisionNode::Booster.new("age", require: true))
    assert_equal({ "booster" => "age", "require" => true }, http.calls.first.json["boosters"])
  end

  def test_boosters_are_not_checked_locally
    ["age", [5], %w[age age], %w[a b c d e], [{ "name" => "age" }]].each do |boosters|
      http = FakeHTTP.new(ok)
      client(http).decide(questions: Q, boosters: boosters)
      assert_equal boosters, http.calls.first.json["boosters"], boosters.inspect
    end
  end

  def test_every_helper_takes_boosters
    http = FakeHTTP.new(lambda { |call|
      ids = call.json["questions"].keys
      FakeHTTP.json(200, { "model" => "m", "answers" => ids.to_h { |id| [id, answer_for(call.json["questions"][id])] } })
    })
    dn = client(http)
    dn.check(state: "s", instructions: "?", boosters: ["age"])
    dn.classify(state: "s", instructions: "?", options: %w[a b], boosters: ["age"])
    dn.score(state: "s", instructions: "?", levels: %w[lo hi], boosters: ["age"])
    dn.number(state: "s", instructions: "?", boosters: ["age"])
    dn.gate(action: "a", boosters: ["age"])
    assert_equal 5, http.calls.size
    http.calls.each { |c| assert_equal ["age"], c.json["boosters"] }
  end

  def answer_for(question)
    case question["type"]
    when "truth" then { "type" => "truth", "truth" => 0.5 }
    when "choice" then { "type" => "choice", "choice" => "a", "confidence" => 0.5, "probabilities" => { "a" => 0.5 } }
    when "score" then { "type" => "score", "score" => 1, "confidence" => 0.5, "probabilities" => { "0" => 0.5 }, "legend" => { "0" => "lo" } }
    when "number" then { "type" => "number", "number" => 1, "expected" => 1, "confidence" => 0.5, "probabilities" => { "1" => 0.5 } }
    end
  end

  def test_decide_many_and_batch_lines_take_boosters
    http = FakeHTTP.new(ok)
    client(http).decide_many([{ questions: Q, boosters: ["age"] }, { questions: Q, boosters: [] }])
    sent = http.calls.map(&:json).sort_by { |b| b.key?("boosters") ? 0 : 1 }
    assert_equal ["age"], sent[0]["boosters"]
    refute sent[1].key?("boosters")

    http = FakeHTTP.new(FakeHTTP.json(201, { "id" => "batch_01J9ZB8Q3T", "state" => "draft" }))
    client(http).batches.create([{ custom_id: "a", questions: Q, boosters: [DecisionNode::Booster.new("age", require: true)] },
                                 { custom_id: "b", questions: Q, boosters: nil, extra: 1 }])
    lines = http.calls.first.body.split("\n").map { |l| JSON.parse(l) }
    assert_equal %w[custom_id model state questions boosters], lines[0].keys
    assert_equal [{ "booster" => "age", "require" => true }], lines[0]["boosters"]
    assert_equal %w[custom_id model state questions extra], lines[1].keys
  end

  def test_the_nesting_limit_counts_booster_options
    deep = (1..127).reduce(1) { |inner, _| [inner] }
    http = FakeHTTP.new(ok)
    dn = client(http)
    err = assert_raises(DecisionNode::BadRequestError) do
      dn.decide(questions: Q, boosters: [DecisionNode::Booster.new("age", options: { "k" => deep })])
    end
    assert_equal "api_usage_error", err.error_type
    assert_match(/nests 131 objects/, err.reason)
    assert_raises(DecisionNode::BadRequestError) do
      dn.check_request("decide", questions: Q, boosters: [{ "booster" => "age", "options" => { "k" => deep } }])
    end
    assert_raises(DecisionNode::BadRequestError) do
      dn.check_request("batches.create", requests: [{ custom_id: "a", questions: Q, boosters: [{ "options" => deep }] }])
    end
    assert_empty http.calls
    assert_nil dn.check_request("decide", questions: Q, boosters: [DecisionNode::Booster.new("age", options: { "k" => 1 })])
  end

  def test_sessions_take_no_boosters
    dn = client(FakeHTTP.new(ok))
    assert_raises(ArgumentError) { dn.open_session(questions: Q, boosters: ["age"]) }
    assert_raises(ArgumentError) { dn.check_request("open_session", questions: Q, boosters: ["age"]) }
  end

  def test_a_fine_tuned_model_name_is_sent_as_given_and_the_pinned_name_read_back
    http = FakeHTTP.new(FakeHTTP.json(200, truth_body.merge("model" => "decisionnode-1.0-flash@acme/fraud:3"),
                                      "x-decisionnode-model" => "decisionnode-1.0-flash@acme/fraud:3"))
    d = client(http).decide(questions: Q, model: "decisionnode-1.0-flash@acme/fraud")
    assert_equal "decisionnode-1.0-flash@acme/fraud", http.calls.first.json["model"]
    assert_equal "decisionnode-1.0-flash@acme/fraud:3", d.model

    http = FakeHTTP.new(ok)
    client(http, model: "decisionnode-1.0-flash@acme/fraud:3").decide(questions: Q)
    assert_equal "decisionnode-1.0-flash@acme/fraud:3", http.calls.first.json["model"]
  end

  # ---- the response

  def evidence_body
    {
      "model" => "decisionnode-1.0",
      "answers" => { "q" => { "type" => "truth", "truth" => 0.97 } },
      "evidence" => {
        "age" => {
          "version" => "age-v3", "status" => "ok", "latency_ms" => 212,
          "results" => [
            { "image" => "a1b2", "age_years" => 27, "low" => 22, "high" => 33, "confidence" => 0.81, "faces" => 1 },
            { "image" => "c3d4", "faces" => 0 }
          ]
        },
        "ai_generated" => {
          "version" => "ai_generated-v2", "status" => "ok", "latency_ms" => 340,
          "results" => [
            { "image" => "a1b2", "generated" => 0.93, "confidence" => 0.86, "method" => "inference",
              "top_generator" => { "name" => "generator-a", "probability" => 0.71 }, "c2pa_signer" => nil },
            { "image" => "c3d4", "generated" => 0.99, "confidence" => 0.99, "method" => "c2pa",
              "top_generator" => nil, "c2pa_signer" => "Example Signer" },
            { "image" => "c3d4", "generated" => 0.12, "confidence" => 0.76, "method" => "inference",
              "top_generator" => nil, "c2pa_signer" => nil, "c2pa" => "untrusted" }
          ]
        },
        "faces" => { "version" => "faces-v1", "status" => "ok", "latency_ms" => 5, "results" => [{ "image" => "a1b2", "count" => 2 }] },
        "late" => { "version" => "late-v1", "status" => "timeout", "latency_ms" => 800, "results" => [] },
        "none" => { "version" => "none-v1", "status" => "skipped", "latency_ms" => 0 }
      },
      "usage" => { "input_tokens" => 341, "output_tokens" => 0, "booster_tokens" => 72, "boosters" => 3 }
    }
  end

  def test_evidence_is_parsed_in_order_with_typed_readings
    d = client(FakeHTTP.new(FakeHTTP.json(200, evidence_body))).decide(questions: Q, images: IMAGES, boosters: %w[age ai_generated])
    assert_equal %w[age ai_generated faces late none], d.evidence.keys

    age = d.evidence["age"]
    assert_instance_of DecisionNode::Evidence, age
    assert_equal ["age-v3", "ok", 212], [age.version, age.status, age.latency_ms]
    first, second = age.results
    assert_instance_of DecisionNode::AgeReading, first
    assert_equal ["a1b2", 1, 27, 22, 33, 0.81], [first.image, first.faces, first.age_years, first.low, first.high, first.confidence]
    assert_instance_of DecisionNode::AgeReading, second
    assert_equal ["c3d4", 0], [second.image, second.faces]
    assert_nil second.age_years
    assert_nil second.low
    assert_nil second.high
    assert_nil second.confidence

    by_inference, by_c2pa = d.evidence["ai_generated"].results
    assert_instance_of DecisionNode::AiGeneratedReading, by_inference
    assert_equal [0.93, 0.86, "inference"], [by_inference.generated, by_inference.confidence, by_inference.method]
    assert_equal DecisionNode::TopGenerator.new("generator-a", 0.71), by_inference.top_generator
    assert_nil by_inference.c2pa_signer
    assert_equal "c2pa", by_c2pa.method
    assert_nil by_c2pa.top_generator
    assert_equal "Example Signer", by_c2pa.c2pa_signer
    assert_nil by_c2pa.c2pa
    untrusted = d.evidence["ai_generated"].results[2]
    assert_instance_of DecisionNode::AiGeneratedReading, untrusted
    assert_equal ["untrusted", nil, nil], [untrusted.c2pa, untrusted.c2pa_signer, untrusted.top_generator]

    unknown = d.evidence["faces"].results.first
    assert_instance_of DecisionNode::UnknownReading, unknown
    assert_equal "a1b2", unknown.image
    assert_equal({ "image" => "a1b2", "count" => 2 }, unknown.raw)
    assert_equal 2, unknown["count"]

    assert_equal ["timeout", 800, []], [d.evidence["late"].status, d.evidence["late"].latency_ms, d.evidence["late"].results]
    assert_equal ["skipped", []], [d.evidence["none"].status, d.evidence["none"].results]

    assert_equal [341, 0, 72, 3], [d.usage.input_tokens, d.usage.output_tokens, d.usage.booster_tokens, d.usage.boosters]
  end

  def test_malformed_readings_are_unknown_and_the_decision_still_parses
    malformed = [
      { "image" => "a1b2", "faces" => 1, "low" => 22, "high" => 33, "confidence" => 0.81 }, # no age_years with a face
      { "image" => "a1b2", "faces" => "1" },
      { "image" => 7, "faces" => 0 },
      { "image" => "a1b2", "faces" => 0, "age_years" => "27" },
      { "image" => "a1b2", "faces" => true },
      { "image" => "a1b2", "faces" => 1, "age_years" => 27.5, "low" => 22, "high" => 33, "confidence" => 0.81 },
      { "image" => "a1b2", "faces" => -1 },
      "not an object"
    ]
    ai_malformed = [
      { "image" => "c3d4", "generated" => "0.9", "confidence" => 0.8, "method" => "inference" },
      { "image" => "c3d4", "generated" => 0.9, "confidence" => 0.8, "method" => 1 },
      { "image" => "c3d4", "generated" => 0.9, "confidence" => 0.8, "method" => "inference", "top_generator" => "x" },
      { "image" => "c3d4", "generated" => 0.9, "confidence" => 0.8, "method" => "inference", "top_generator" => { "name" => "x" } },
      { "image" => "c3d4", "generated" => 0.9, "confidence" => 0.8, "method" => "c2pa", "c2pa_signer" => 5 },
      # No top_generator, and no c2pa_signer key: each is required.
      { "image" => "c3d4", "generated" => 0.9, "confidence" => 0.8, "method" => "inference", "c2pa_signer" => nil },
      { "image" => "c3d4", "generated" => 0.9, "confidence" => 0.8, "method" => "inference",
        "top_generator" => { "name" => "x", "probability" => 0.5 } },
      # A c2pa that is not a string.
      { "image" => "c3d4", "generated" => 0.9, "confidence" => 0.8, "method" => "inference",
        "top_generator" => nil, "c2pa_signer" => nil, "c2pa" => 5 }
    ]
    body = truth_body.merge("evidence" => {
                              "age" => { "status" => "ok", "results" => malformed },
                              "ai_generated" => { "status" => "ok", "results" => ai_malformed }
                            })
    d = client(FakeHTTP.new(FakeHTTP.json(200, body))).decide(questions: Q)
    assert_equal 0.5, d["q"].truth
    (d.evidence["age"].results + d.evidence["ai_generated"].results).each do |r|
      assert_instance_of DecisionNode::UnknownReading, r
    end
    assert_equal malformed[0..-2] + [{ "value" => "not an object" }], d.evidence["age"].results.map(&:raw)
    assert_nil d.evidence["age"].results.last.image
    assert_equal "a1b2", d.evidence["age"].results.first.image
  end

  def test_an_entry_that_is_not_an_object
    d = client(FakeHTTP.new(FakeHTTP.json(200, truth_body.merge("evidence" => { "age" => "nope" })))).decide(questions: Q)
    ev = d.evidence["age"]
    assert_equal [nil, nil, nil, [], "nope"], [ev.version, ev.status, ev.latency_ms, ev.results, ev.raw]
  end

  def test_no_evidence_or_booster_usage_without_boosters
    d = client(FakeHTTP.new(ok)).decide(questions: Q)
    assert_nil d.evidence
    assert_nil d.usage.booster_tokens
    assert_nil d.usage.boosters
    assert_equal 5, d.usage.input_tokens
  end

  def test_batch_results_read_evidence
    text = JSON.generate({ "custom_id" => "a", "status" => 200, "body" => evidence_body, "headers" => {} })
    http = FakeHTTP.new(DecisionNode::HTTPResponse.new(200, { "content-type" => "application/x-ndjson" }, "#{text}\n"))
    result = client(http).batches.results("batch_01J9ZB8Q3T").first
    assert_equal 27, result.decision.evidence["age"].results.first.age_years
    assert_equal 3, result.decision.usage.boosters
  end

  # ---- the boosters header

  def test_header_parsing
    parse = ->(v) { DecisionNode::BoosterStatus.parse(v).transform_values(&:to_a) }
    assert_equal({ "age" => ["ok", 212], "ai_generated" => ["timeout", 800] }, parse.("age=ok:212,ai_generated=timeout:800"))
    assert_equal({ "age" => ["ok", 212], "b" => ["error", nil], "c" => ["skipped", nil], "d" => ["", nil] },
                 parse.(" age = ok : 212 , b=error:x,,c=skipped, nonsense ,=ok:1,d="))
    assert_equal({ "age" => ["error", 9], "b" => ["ok", 1] }, parse.("age=ok:1,b=ok:1,age=error:9"))
    assert_equal({ "age" => ["ok", nil] }, parse.("age=ok:-1"))
    assert_equal({}, parse.(nil))
    assert_equal({}, parse.(""))
    assert_equal %w[age b], DecisionNode::BoosterStatus.parse("age=ok:1,b=ok:1,age=error:9").keys
  end

  def test_every_error_carries_the_boosters_header
    http = FakeHTTP.new(FakeHTTP.json(400, { "detail" => { "error_type" => "booster_unknown", "message" => "Unknown booster: agee" } },
                                      "x-decisionnode-boosters" => "agee=error:0"))
    err = assert_raises(DecisionNode::BadRequestError) { client(http).decide(questions: Q, boosters: ["agee"]) }
    assert_equal "booster_unknown", err.error_type
    assert_equal "Unknown booster: agee", err.message
    assert_equal({ "agee" => DecisionNode::BoosterStatus.new("error", 0) }, err.boosters)

    http = FakeHTTP.new(FakeHTTP.json(400, { "detail" => { "error_type" => "booster_input_mismatch", "message" => "x" } }))
    err = assert_raises(DecisionNode::BadRequestError) { client(http).decide(questions: Q, boosters: ["age"]) }
    assert_equal "booster_input_mismatch", err.error_type
    assert_equal({}, err.boosters)

    http = FakeHTTP.new(FakeHTTP.json(400, { "detail" => { "error_type" => "api_usage_error", "message" => "Invalid request." } },
                                      "x-decisionnode-error" => "boosters: more than 4 entries"))
    err = assert_raises(DecisionNode::BadRequestError) { client(http).decide(questions: Q, boosters: %w[a b c d e]) }
    assert_equal "boosters: more than 4 entries", err.reason

    assert_equal({}, DecisionNode::DecisionNodeError.new("local").boosters)
  end

  def test_a_403_that_is_not_a_refusal_is_permission_denied_and_not_retried
    %w[booster_not_enabled workspace_suspended].each do |type|
      http = FakeHTTP.new(FakeHTTP.json(403, { "detail" => { "error_type" => type, "message" => "m" } },
                                        "x-decisionnode-boosters" => "age=error:0"))
      err = assert_raises(DecisionNode::PermissionDeniedError) { client(http).decide(questions: Q, boosters: ["age"]) }
      assert_equal type, err.error_type
      assert_equal 1, http.calls.size
    end
    http = FakeHTTP.new(FakeHTTP.json(403, { "detail" => { "error_type" => "refusal_error", "message" => "m", "category" => "harm" } }))
    err = assert_raises(DecisionNode::RefusalError) { client(http).decide(questions: Q, boosters: ["age"]) }
    assert_equal "harm", err.category
  end

  def test_booster_unavailable_is_retried_twice_then_raised_with_the_header
    body = { "detail" => { "error_type" => "booster_unavailable", "message" => "The booster 'age' did not answer in time." } }
    http = FakeHTTP.new(FakeHTTP.json(529, body, "retry-after-ms" => "250", "x-decisionnode-boosters" => "age=timeout:800,ai_generated=ok:340"))
    dn = client(http)
    err = assert_raises(DecisionNode::OverloadedError) do
      dn.decide(questions: Q, boosters: [DecisionNode::Booster.new("age", require: true), "ai_generated"])
    end
    assert_equal 3, http.calls.size
    assert_equal [0.25, 0.25], dn.sleeps
    assert_equal "booster_unavailable", err.error_type
    assert_equal 0.25, err.retry_after
    assert_equal %w[age ai_generated], err.boosters.keys
    assert_equal ["timeout", 800], err.boosters["age"].to_a
    assert_equal ["ok", 340], err.boosters["ai_generated"].to_a
  end

  # ---- models

  def test_models_read_fine_tuned_entries
    http = FakeHTTP.new(FakeHTTP.json(200, { "models" => [
                                        { "name" => "decisionnode-1.0-flash", "description" => "d", "release_date" => "2026-10-01",
                                          "version" => "decisionnode-1.0-flash-2026-10-01", "max_images" => 16 },
                                        { "name" => "decisionnode-1.0-flash@acme/fraud:3", "description" => "Claims fraud",
                                          "release_date" => "2026-10-09", "version" => "decisionnode-1.0-flash@acme/fraud:3",
                                          "fine_tuned" => true, "base" => "decisionnode-1.0-flash-2026-10-01",
                                          "adapter_version" => 3, "status" => "deployed", "max_images" => 16 },
                                        { "name" => "decisionnode-1.0-flash@acme/fraud:4", "description" => "Claims fraud",
                                          "release_date" => "2026-10-09", "fine_tuned" => true, "base" => "decisionnode-1.0-flash",
                                          "adapter_version" => "4", "status" => "ready" }
                                      ] }))
    catalogue, deployed, ready = client(http).models
    assert_nil catalogue.fine_tuned
    refute catalogue.fine_tuned?
    assert_nil catalogue.base
    assert_nil catalogue.adapter_version
    assert_nil catalogue.status
    assert_equal [true, "decisionnode-1.0-flash-2026-10-01", 3, "deployed"],
                 [deployed.fine_tuned, deployed.base, deployed.adapter_version, deployed.status]
    assert deployed.fine_tuned?
    assert_equal true, deployed.limits["fine_tuned"]
    assert_equal 3, deployed.limits["adapter_version"]
    assert_equal "ready", ready.status
    assert_nil ready.adapter_version
  end

  def test_held_limits_are_found_for_a_fine_tuned_name
    models = { "models" => [{ "name" => "decisionnode-1.0-flash@acme/fraud", "description" => "d", "release_date" => "2026-10-09",
                              "fine_tuned" => true, "max_images" => 1 }] }
    http = FakeHTTP.new(FakeHTTP.json(200, models))
    dn = client(http)
    dn.models
    err = assert_raises(DecisionNode::ValidationError) do
      dn.check_request("decide", questions: Q, images: IMAGES, model: "decisionnode-1.0-flash@acme/fraud")
    end
    assert_equal 1, err.entries.first.dig("ctx", "max_length")
  end
end
