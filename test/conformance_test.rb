# frozen_string_literal: true

# Runs every case of the DecisionNode conformance suite against its mock server.
#
#   DECISIONNODE_CONFORMANCE_DIR=/path/to/decision-node-conformance bundle exec rake conformance
#
# The variable is required: when it is unset, or the suite is not found where it
# points, the tests fail. They are never skipped.

require "minitest/autorun"
require "digest"
require "json"
require "net/http"
require "securerandom"
require "decisionnode"

module Conformance
  ROOT = ENV.fetch("DECISIONNODE_CONFORMANCE_DIR", "").then { |dir| dir.empty? ? nil : File.expand_path(dir) }
  KINDS = %w[requests responses errors behaviour constants].freeze
  ENV_VARS = %w[DECISIONNODE_API_KEY DECISIONNODE_BASE_URL DECISIONNODE_MODEL].freeze
  EXACT = %w[probabilities legend raw entries safety body limits evidence boosters fallback cost].freeze
  # Compared whole and in their key order too: evidence in the request's order, an
  # error's boosters in the header's.
  ORDERED = %w[evidence boosters].freeze
  READ_TIMEOUT_MS = 10_000

  class Fail < StandardError; end

  module_function

  def available?
    return false if ROOT.nil?

    File.directory?(File.join(ROOT, "cases")) && File.file?(File.join(ROOT, "mock", "server.py"))
  end

  def cases
    @cases ||= KINDS.to_h do |kind|
      files = Dir[File.join(ROOT, "cases", kind, "*.json")]
      [kind, files.map { |f| JSON.parse(File.read(f, encoding: "UTF-8")) }]
    end
  end

  # ---- the mock

  def mock_url
    @mock_url ||= begin
      python = ENV.fetch("PYTHON", "python3")
      @mock = IO.popen([python, File.join(ROOT, "mock", "server.py"), "--port", "0",
                        "--cases", File.join(ROOT, "cases")], err: File::NULL)
      line = @mock.gets.to_s.strip
      raise "the mock did not start: #{line.inspect}" unless line.start_with?("listening on ")

      Minitest.after_run { stop_mock }
      line.delete_prefix("listening on ")
    end
  end

  def stop_mock
    return unless @mock

    Process.kill("TERM", @mock.pid)
    Process.wait(@mock.pid)
  rescue StandardError
    nil
  end

  # The recorded requests of a session, without pongs, and the pong count.
  def mock_log(session, path: nil)
    query = { "session" => session }
    query["path"] = path if path
    uri = URI("#{mock_url}/_mock/requests?#{URI.encode_www_form(query)}")
    out = JSON.parse(Net::HTTP.get(uri), max_nesting: false)
    out["pongs"] = out["requests"].count { |r| r["method"] == "PONG" }
    out["requests"] = out["requests"].reject { |r| r["method"] == "PONG" }
    out
  end

  # The session's clock in epoch seconds: the SDK's clock for a case with client.clock "mock".
  def mock_clock_now(session)
    uri = URI("#{mock_url}/_mock/clock?#{URI.encode_www_form('session' => session)}")
    Float(JSON.parse(Net::HTTP.get(uri)).fetch("epoch_seconds"))
  end

  def mock_clock(session, body)
    uri = URI("#{mock_url}/_mock/clock?#{URI.encode_www_form('session' => session)}")
    Net::HTTP.post(uri, JSON.generate(body), "Content-Type" => "application/json")
  end

  # ---- comparison

  # An expected {"$pattern" => regex} matches any String the regex finds.
  def pattern?(value)
    value.is_a?(Hash) && value.size == 1 && value["$pattern"].is_a?(String)
  end

  def same?(a, b)
    if pattern?(a)
      b.is_a?(String) && Regexp.new(a["$pattern"]).match?(b)
    elsif [true, false].include?(a) || [true, false].include?(b)
      a.equal?(b)
    elsif a.is_a?(Numeric) && b.is_a?(Numeric)
      a == b
    elsif a.is_a?(Hash) && b.is_a?(Hash)
      a.keys.sort == b.keys.sort && a.all? { |k, v| same?(v, b[k]) }
    elsif a.is_a?(Array) && b.is_a?(Array)
      a.size == b.size && a.zip(b).all? { |x, y| same?(x, y) }
    else
      a.instance_of?(b.class) && a == b
    end
  end

  def match!(expected, actual, path)
    if expected.is_a?(Hash) && actual.is_a?(Hash) && !pattern?(expected)
      expected.each do |k, v|
        raise Fail, "#{path}.#{k}: missing (expected #{short(v)})" unless actual.key?(k)

        if EXACT.include?(k)
          raise Fail, "#{path}.#{k}: expected #{short(v)}, got #{short(actual[k])}" unless same?(v, actual[k])
          if ORDERED.include?(k) && v.is_a?(Hash) && v.keys != actual[k].keys
            raise Fail, "#{path}.#{k}: expected the order #{v.keys}, got #{actual[k].keys}"
          end
        else
          match!(v, actual[k], "#{path}.#{k}")
        end
      end
    elsif !same?(expected, actual)
      raise Fail, "#{path}: expected #{short(expected)}, got #{short(actual)}"
    end
  end

  def short(value)
    text = JSON.generate(value)
    text.size < 160 ? text : "#{text[0, 157]}..."
  rescue StandardError
    value.inspect
  end

  def pointer(doc, ptr)
    return [true, doc] if ptr.empty?

    ptr[1..].split("/").reduce([true, doc]) do |(_, cur), raw|
      part = raw.gsub("~1", "/").gsub("~0", "~")
      if cur.is_a?(Hash) && cur.key?(part)
        [true, cur[part]]
      elsif cur.is_a?(Array) && part.match?(/\A\d+\z/) && part.to_i < cur.size
        [true, cur[part.to_i]]
      else
        return [false, nil]
      end
    end
  end

  JSON_TYPES = {
    "string" => ->(v) { v.is_a?(String) },
    "number" => ->(v) { v.is_a?(Numeric) },
    "integer" => ->(v) { v.is_a?(Integer) },
    "boolean" => ->(v) { [true, false].include?(v) },
    "null" => lambda(&:nil?),
    "array" => ->(v) { v.is_a?(Array) },
    "object" => ->(v) { v.is_a?(Hash) }
  }.freeze

  # Key order of the object at `ptr` in a JSON text.
  def ordered_keys_of(text, ptr)
    doc = JSON.parse(text, object_class: OrderedKeys, max_nesting: false)
    found, node = pointer(doc, ptr)
    found && node.is_a?(Hash) ? node.keys : []
  end

  class OrderedKeys < Hash; end

  def in_range!(range, value, what)
    raise Fail, format("%s %.0f is below %s", what, value, range["min"]) if range.key?("min") && value < range["min"]
    raise Fail, format("%s %.0f is above %s", what, value, range["max"]) if range.key?("max") && value > range["max"]
  end

  # ---- normalisation into the neutral shapes the cases use

  PLACE_FIELDS = %w[present confidence image width height].freeze

  def norm_places(answer, list, fields)
    { "kind" => list, "count" => answer.count, "present" => answer.present, "complete" => answer.complete,
      list => answer.public_send(list).map { |p| fields.to_h { |k| [k, p.public_send(k)] } },
      "image" => answer.image, "width" => answer.width, "height" => answer.height }
  end

  def norm_answer(answer)
    case answer
    when DecisionNode::PointsAnswer then norm_places(answer, "points", %w[x y confidence])
    when DecisionNode::BoxesAnswer then norm_places(answer, "boxes", %w[x1 y1 x2 y2 confidence])
    when DecisionNode::PointAnswer
      %w[x y].concat(PLACE_FIELDS).to_h { |k| [k, answer.public_send(k)] }.merge("kind" => "point")
    when DecisionNode::BoxAnswer
      %w[x1 y1 x2 y2].concat(PLACE_FIELDS).to_h { |k| [k, answer.public_send(k)] }.merge("kind" => "box")
    when DecisionNode::NumberAnswer
      { "kind" => "number", "number" => answer.number, "expected" => answer.expected,
        "confidence" => answer.confidence, "probabilities" => answer.probabilities }
    when DecisionNode::TruthAnswer
      { "kind" => "truth", "truth" => answer.truth }
    when DecisionNode::ChoiceAnswer
      { "kind" => "choice", "choice" => answer.choice, "confidence" => answer.confidence,
        "probabilities" => answer.probabilities }
    when DecisionNode::ScoreAnswer
      { "kind" => "score", "score" => answer.score, "confidence" => answer.confidence,
        "probabilities" => answer.probabilities.transform_keys(&:to_s),
        "legend" => answer.legend.transform_keys(&:to_s) }
    when DecisionNode::UnknownAnswer
      { "kind" => "unknown", "type" => answer.type, "raw" => answer.raw }
    else
      raise Fail, "not an answer: #{answer.class}"
    end
  end

  def norm_usage(usage)
    usage && { "input_tokens" => usage.input_tokens, "output_tokens" => usage.output_tokens,
               "video_frames" => usage.video_frames, "video_seconds" => usage.video_seconds,
               "booster_tokens" => usage.booster_tokens, "boosters" => usage.boosters,
               "cost" => norm_cost(usage.cost) }
  end

  def norm_cost(cost)
    cost && { "usd" => cost.usd, "model_usd" => cost.model_usd, "boosters_usd" => cost.boosters_usd,
              "free_tier" => cost.free_tier }
  end

  AGE_FIELDS = %w[image faces age_years low high confidence].freeze
  AI_GENERATED_FIELDS = %w[image generated confidence method c2pa_signer].freeze

  def norm_reading(reading)
    case reading
    when DecisionNode::AgeReading
      AGE_FIELDS.to_h { |k| [k, reading.public_send(k)] }.merge("kind" => "age")
    when DecisionNode::AiGeneratedReading
      top = reading.top_generator
      AI_GENERATED_FIELDS.to_h { |k| [k, reading.public_send(k)] }
                         .merge("kind" => "ai_generated", "top_generator" => top && { "name" => top.name, "probability" => top.probability })
                         .merge("c2pa" => reading.c2pa)
    when DecisionNode::OcrReading
      { "kind" => "ocr", "image" => reading.image, "text" => reading.text, "truncated" => reading.truncated }
    when DecisionNode::FaceDetectionReading
      { "kind" => "face_detection", "image" => reading.image, "faces" => reading.faces,
        "detections" => reading.detections.map { |d| { "box" => norm_box(d.box), "confidence" => d.confidence } } }
    when DecisionNode::WantedPersonReading
      { "kind" => "wanted_person", "image" => reading.image, "faces" => reading.faces,
        "matches" => reading.matches.map { |m| { "box" => norm_box(m.box), "score" => m.score, "reference" => m.reference } } }
    when DecisionNode::UnknownReading
      { "kind" => "unknown", "raw" => reading.raw }
    else
      raise Fail, "not a reading: #{reading.class}"
    end
  end

  def norm_box(box)
    { "x1" => box.x1, "y1" => box.y1, "x2" => box.x2, "y2" => box.y2 }
  end

  def norm_evidence(evidence)
    evidence&.transform_values do |e|
      { "version" => e.version, "status" => e.status, "latency_ms" => e.latency_ms,
        "billed_calls" => e.billed_calls, "results" => e.results.map { |r| norm_reading(r) } }
    end
  end

  def norm_decision(decision)
    {
      "model" => decision.model,
      "request_id" => decision.request_id,
      "latency_ms" => decision.latency_ms,
      "usage" => norm_usage(decision.usage),
      "safety" => decision.safety&.to_h,
      "answers" => decision.answers.transform_values { |a| norm_answer(a) },
      "evidence" => norm_evidence(decision.evidence),
      "fallback" => decision.fallback && { "served_model" => decision.fallback.served_model,
                                           "requested_model" => decision.fallback.requested_model },
      "warnings" => decision.warnings,
      "raw" => decision.raw
    }
  end

  def norm_error(err)
    get = ->(name) { err.respond_to?(name) ? err.public_send(name) : nil }
    {
      "status" => get.(:status),
      "error_type" => get.(:error_type),
      # The error's own message, "" when the server sent none.
      "message" => err.message,
      "request_id" => get.(:request_id),
      "reason" => get.(:reason),
      "category" => get.(:category),
      "safety" => get.(:safety)&.to_h,
      "entries" => get.(:entries),
      "retry_after" => get.(:retry_after),
      "boosters" => get.(:boosters)&.transform_values { |b| { "status" => b.status, "latency_ms" => b.latency_ms } }
    }
  end

  def norm_session(session)
    session.raw.merge("answers" => session.answers.transform_values { |a| norm_answer(a) })
  end

  def norm_batch_result(result)
    out = { "custom_id" => result.custom_id, "status" => result.status, "headers" => result.headers }
    out["decision"] = norm_decision(result.decision) if result.decision
    out["error"] = result.error if result.error
    out
  end

  def norm_event(event)
    case event
    when DecisionNode::Reply
      out = { "seq" => event.seq, "answers" => event.answers.transform_values { |a| norm_answer(a) },
              "usage" => norm_usage(event.usage), "latency_ms" => event.latency_ms, "safety" => event.safety }
      out["dropped"] = event.dropped unless event.dropped.nil?
      { "reply" => out }
    when DecisionNode::FrameError
      out = { "seq" => event.seq, "error_type" => event.error_type, "message" => event.message }
      out["category"] = event.category unless event.category.nil?
      out["retry_after_ms"] = event.retry_after_ms unless event.retry_after_ms.nil?
      out["usage"] = norm_usage(event.usage) unless event.usage.nil?
      out["safety"] = event.safety unless event.safety.nil?
      { "frame_error" => out }
    when DecisionNode::SessionClosed
      { "closed" => { "code" => event.code, "reopen" => event.reopen } }
    else
      raise Fail, "unknown session event #{event.inspect}"
    end
  end

  def check_error!(spec, err, path)
    cls = spec["error"] || spec["class"]
    names = err.class.ancestors.map { |c| c.name.to_s.split("::").last }
    if spec["subclass_ok"]
      raise Fail, "#{path}: expected #{cls} or a subclass, got #{err.class}" unless names.include?(cls)
    elsif err.class.name.split("::").last != cls
      raise Fail, "#{path}: expected #{cls}, got #{err.class} (#{err.message})"
    end
    match!(spec["fields"] || {}, norm_error(err), "#{path}.fields")
  end

  # batch_results whole, or count with batch_results_sample by index.
  def check_results_spec!(spec, results, path)
    results = results.to_a
    check_batch_results!(spec["batch_results"], results, "#{path}.batch_results") if spec.key?("batch_results")
    if spec.key?("count") && results.size != spec["count"]
      raise Fail, "#{path}: expected #{spec['count']} results, got #{results.size}"
    end
    (spec["batch_results_sample"] || []).each do |sample|
      i = sample["index"]
      raise Fail, "#{path}: no result #{i} of #{results.size}" if i >= results.size

      check_batch_result!(sample.except("index"), results[i], "#{path}.batch_results[#{i}]")
    end
  end

  def check_batch_results!(expected, results, path)
    results = results.to_a
    raise Fail, "#{path}: expected #{expected.size} results, got #{results.size}" unless results.size == expected.size

    expected.zip(results).each_with_index { |(spec, res), i| check_batch_result!(spec, res, "#{path}[#{i}]") }
  end

  def check_batch_result!(spec, res, where)
    got = norm_batch_result(res)
    %w[custom_id status headers].each do |key|
      next unless spec.key?(key)

      if key == "headers"
        match!(spec[key], got[key], "#{where}.headers")
      elsif !same?(spec[key], got[key])
        raise Fail, "#{where}.#{key}: expected #{short(spec[key])}, got #{short(got[key])}"
      end
    end
    if spec.key?("decision")
      raise Fail, "#{where}: expected a decision, got none" unless got.key?("decision")

      match!(spec["decision"], got["decision"], "#{where}.decision")
    end
    if spec.key?("error")
      raise Fail, "#{where}: expected an error value, got none" unless got.key?("error")

      check_error!(spec["error"], got["error"], "#{where}.error")
    end
    raise Fail, "#{where}: expected no decision" if spec["no_decision"] && got.key?("decision")
  end

  # ---- calls

  def image_bytes(args)
    data = args.key?("path") ? File.binread(File.join(ROOT, args["path"])) : args["data_base64"].unpack1("m")
    # The image's own bytes followed by zero bytes: the header is unchanged.
    data += "\0".b * [0, args["pad_to"] - data.bytesize].max if args.key?("pad_to")
    data
  end

  def decode(value, ctx = {})
    if value.is_a?(Hash) && value.size == 1
      key, args = value.first
      case key
      when "$ref" then return resolve_ref(args, ctx)
      when "$text" then return args["repeat"] * args["times"]
      when "$list" then return Array.new(args["count"]) { |i| decode(with_index(args["item"], i), ctx) }
      when "$nest" then return args["depth"].times.reduce(decode(args["value"], ctx)) { |inner, _| [inner] }
      when "$truth" then return DecisionNode.truth(args["instructions"], if_true: args["true"], if_false: args["false"])
      when "$choice" then return DecisionNode.choice(args["instructions"], args["options"])
      when "$score" then return DecisionNode.score(args["instructions"], args["levels"])
      when "$number"
        return DecisionNode.number(args["instructions"], min: args["min"], max: args["max"], step: args["step"])
      when "$point" then return DecisionNode.point(args["instructions"], image: args["image"], units: args["units"], max: args["max"])
      when "$box" then return DecisionNode.box(args["instructions"], image: args["image"], units: args["units"], max: args["max"])
      when "$booster" then return booster(args.transform_values { |v| decode(v, ctx) })
      when "$image" then return image(args.transform_values { |v| decode(v, ctx) })
      when "$video" then return video(args, ctx)
      when "$frame" then return frame(args)
      end
    end
    case value
    when Hash then value.transform_values { |v| decode(v, ctx) }
    when Array then value.map { |v| decode(v, ctx) }
    else value
    end
  end

  # A value with "{i}" in every string replaced by the index.
  def with_index(value, index)
    case value
    when String then value.gsub("{i}", index.to_s)
    when Hash then value.transform_values { |v| with_index(v, index) }
    when Array then value.map { |v| with_index(v, index) }
    else value
    end
  end

  def image(args)
    id = args["id"]
    type = args["media_type"]
    return DecisionNode::Image.new(id, url: args["url"], media_type: type) if args.key?("url")
    return DecisionNode::Image.new(id, upload_id: args["upload_id"], media_type: type) if args.key?("upload_id")
    if args.key?("path") && !args.key?("pad_to")
      return DecisionNode::Image.new(id, path: File.join(ROOT, args["path"]), media_type: type)
    end

    # Without media_type the client is given the bytes alone and detects the format.
    DecisionNode::Image.new(id, data: image_bytes(args), media_type: type)
  end

  # Booster(name, images, require, options): each only when the case gives it.
  def booster(args)
    kw = args.slice("images", "require", "options").to_h { |k, v| [k.to_sym, v] }
    DecisionNode::Booster.new(args["name"], **kw)
  end

  # Video(id, frames, fps, start, end): fps, start and end only when the case gives them.
  def video(args, ctx)
    kw = args.slice("fps", "start", "end").to_h { |k, v| [k.to_sym, v] }
    DecisionNode::Video.new(args["id"], frames: args["frames"].map { |f| decode(f, ctx) }, **kw)
  end

  # VideoFrame(t, data, media_type): path and data_base64 as raw bytes, data_text as base64 text.
  def frame(args)
    kw = args.key?("media_type") ? { media_type: args["media_type"] } : {}
    if args.key?("data_text")
      DecisionNode::VideoFrame.new(args["t"], base64: args["data_text"], **kw)
    else
      DecisionNode::VideoFrame.new(args["t"], data: image_bytes(args), **kw)
    end
  end

  def resolve_ref(path, ctx)
    name, rest = path.split(".", 2)
    (rest ? rest.split(".") : []).reduce(ctx.fetch(name)) do |cur, part|
      case cur
      when Hash then cur[part]
      when Array then cur[Integer(part)]
      else cur.public_send(part)
      end
    end
  end

  def kwargs(hash)
    hash.to_h { |k, v| [{ "true" => :if_true, "false" => :if_false }.fetch(k, k.to_sym), v] }
  end

  def invoke(client, call, ctx = {})
    method = call["method"]
    raw_args = call["args"] || {}
    return client.decide_raw(raw_args["body"]) if method == "decide_raw"

    args = raw_args.transform_values { |v| decode(v, ctx) }
    if call["check"]
      # The same request handed to the SDK's check instead of being sent.
      return client.check_request(method, kwargs(args.except("batch_id")))
    end

    case method
    when "models" then client.models
    when "upload" then client.upload(args["images"])
    when "decide_many"
      kw = args.key?("concurrency") ? { concurrency: args["concurrency"] } : {}
      client.decide_many(args["requests"], **kw)
    when "run_batch" then client.run_batch(args["requests"], **kwargs(args.except("requests")))
    when "supervise" then supervise(client, args)
    when /\Abatches\.(.+)\z/ then batches(client.batches, Regexp.last_match(1), args)
    else client.public_send(method, **kwargs(args))
    end
  end

  def batches(api, name, args)
    case name
    when "create" then api.create(args.fetch("requests", []))
    when "add" then api.add(args["batch_id"], args["requests"])
    when "list" then api.list(**kwargs(args))
    else api.public_send(name, args["batch_id"])
    end
  end

  def supervise(client, args)
    replies = []
    interval = args.fetch("feed_interval_ms", 0) / 1000.0
    readings = args["feed"]
    feed = Enumerator.new do |y|
      readings.each_with_index do |reading, i|
        sleep(interval) if i.positive?
        y << reading
      end
    end
    closed = client.supervise(args["body"], feed, ->(event) { replies << event })
    { "supervised" => true, "replies" => replies, "closed" => closed }
  end

  # Replaces the client's wait between attempts with a recorder that returns at once.
  def record_waits(client)
    waits = []
    client.instance_variable_set(:@sleeper, ->(seconds) { waits << seconds })
    waits
  end

  def fill(text)
    text.gsub("{mock_url}", mock_url).gsub("{mock_port}", URI(mock_url).port.to_s)
  end

  # A transport a caller might write: Net::HTTP, following redirects as most
  # HTTP libraries do by default, and not declaring that it never follows one.
  class FollowingTransport
    def call(method, url, headers, body, timeout)
      uri = URI(url)
      5.times do
        http = Net::HTTP.new(uri.host, uri.port)
        http.open_timeout = http.read_timeout = timeout
        req = (method == "GET" ? Net::HTTP::Get : Net::HTTP::Post).new(uri.request_uri)
        headers.each { |k, v| req[k] = v }
        req.body = body if body
        res = http.request(req)
        unless res.is_a?(Net::HTTPRedirection)
          return DecisionNode::HTTPResponse.new(res.code.to_i, res.to_hash.transform_values { |v| v.join(", ") }, res.body.to_s)
        end

        uri = URI.join(uri.to_s, res["location"])
      end
    end
  end

  def make_client(case_, extra_headers)
    ENV_VARS.each { |v| ENV.delete(v) }
    (case_["env"] || {}).each { |k, v| ENV[k] = fill(v) }
    spec = case_["client"] || {}
    kw = {}
    %w[api_key model timeout max_retries inline_threshold upload_timeout].each { |k| kw[k.to_sym] = spec[k] unless spec[k].nil? }
    if spec.key?("base_url")
      kw[:base_url] = fill(spec["base_url"]) unless spec["base_url"].nil?
    else
      kw[:base_url] = mock_url
    end
    kw[:headers] = (spec["headers"] || {}).merge(extra_headers)
    kw[:http_client] = FollowingTransport.new if spec["http_client"] == "caller_following_redirects"
    DecisionNode.new(**kw)
  end

  # ---- requests

  def run_requests(case_)
    session = SecureRandom.hex(16)
    extra = { "x-mock-session" => session }
    extra["x-mock-scenario"] = "request/#{case_['id']}" if case_["mock"]
    invoke(make_client(case_, extra), case_["call"])
    sleep 0.02
    log = mock_log(session)["requests"]
    exp = case_["expect"]
    if exp.key?("request")
      raise Fail, "expected 1 request, the mock received #{log.size}" unless log.size == 1

      check_request!(exp["request"], log.first, "request")
    else
      check_request_list!(exp["requests"], log)
    end
  end

  def describe(log)
    log.map { |r| "#{r['method']} #{r['path']}" }
  end

  def check_request_list!(expected, log)
    raise Fail, "expected #{expected.size} requests, the mock received #{log.size}: #{describe(log)}" unless log.size == expected.size

    i = 0
    while i < expected.size
      unless expected[i]["parallel"]
        check_request!(expected[i], log[i], "requests[#{i}]")
        i += 1
        next
      end
      j = i
      j += 1 while j < expected.size && expected[j]["parallel"]
      # Requests sent in parallel may arrive in any order: each entry is
      # matched to a recorded request not yet taken, backtracking when a later
      # entry finds none.
      fits = (i...j).to_h do |k|
        [k, (i...j).select do |g|
          check_request!(expected[k], log[g], "requests[#{k}]")
          true
        rescue Fail
          false
        end]
      end
      unless assign((i...j).to_a, fits, {})
        bad = fits.find { |_, gs| gs.empty? }&.first || i
        reason = begin
          check_request!(expected[bad], log[bad], "requests[#{bad}]")
          "no assignment of the parallel requests matches"
        rescue Fail => e
          e.message
        end
        raise Fail, "no order of the parallel requests matches: #{reason}"
      end

      i = j
    end
  end

  # Gives each entry one of the requests it fits, none taken twice.
  def assign(entries, fits, taken)
    return true if entries.empty?

    first, *rest = entries
    fits[first].any? do |g|
      next false if taken.key?(g)

      taken[g] = true
      assign(rest, fits, taken) || (taken.delete(g) && false)
    end
  end

  def parse_jsonl(text)
    stripped = text.to_s.strip
    return [] if stripped.empty?
    return JSON.parse(stripped, max_nesting: false) if stripped.start_with?("[")

    text.split("\n").reject { |l| l.strip.empty? }.map { |l| JSON.parse(l, max_nesting: false) }
  end

  def check_request!(exp, got, where)
    raise Fail, "#{where} method: expected #{exp['method']}, got #{got['method']} #{got['path']}" unless got["method"] == exp["method"]
    raise Fail, "#{where} path: expected #{exp['path']}, got #{got['path']}" if exp.key?("path") && got["path"] != exp["path"]
    if exp.key?("path_pattern") && !got["path"].match?(Regexp.new(exp["path_pattern"]))
      raise Fail, "#{where} path: #{got['path']} does not match #{exp['path_pattern']}"
    end
    if exp.key?("query")
      query = URI.decode_www_form(got["query"].to_s).each_with_object({}) { |(k, v), h| h[k] ||= v }
      raise Fail, "#{where} query: expected #{exp['query']}, got #{query}" unless query == exp["query"]
    end
    if exp.key?("status") && got["status"] != exp["status"]
      raise Fail, "#{where} status: the mock answered #{got['status']}, expected #{exp['status']}"
    end
    headers = got["headers"]
    (exp["headers"] || {}).each do |name, value|
      actual = headers[name.downcase]
      raise Fail, "#{where} header #{name}: expected #{value.inspect}, got #{actual.inspect}" unless actual == value
    end
    (exp["header_patterns"] || {}).each do |name, pattern|
      actual = headers[name.downcase]
      raise Fail, "#{where} header #{name}: #{actual.inspect} does not match #{pattern}" unless actual&.match?(Regexp.new(pattern))
    end
    (exp["absent_headers"] || []).each do |name|
      raise Fail, "#{where} header #{name} must not be sent" if headers.key?(name.downcase)
    end
    if exp.key?("body_base64")
      raise Fail, "#{where} body: the bytes differ" unless got["body_base64"] == exp["body_base64"]

      return
    end
    if exp.key?("body_sha256")
      digest = Digest::SHA256.hexdigest(got["body_base64"].to_s.unpack1("m"))
      raise Fail, "#{where} body: sha256 #{digest}, expected #{exp['body_sha256']}" unless digest == exp["body_sha256"]

      return
    end
    if exp.key?("jsonl")
      lines = parse_jsonl(got["body_text"])
      raise Fail, "#{where} body lines: expected #{short(exp['jsonl'])}, got #{short(lines)}" unless same?(exp["jsonl"], lines)

      return
    end
    if exp.key?("jsonl_count") || exp.key?("jsonl_checks")
      lines = parse_jsonl(got["body_text"])
      if exp.key?("jsonl_count") && lines.size != exp["jsonl_count"]
        raise Fail, "#{where} body: expected #{exp['jsonl_count']} lines, got #{lines.size}"
      end
      (exp["jsonl_checks"] || []).each do |check|
        raise Fail, "#{where} body: no line #{check['line']}" if check["line"] >= lines.size

        check_value!(check, lines[check["line"]], "#{where} line #{check['line']}")
      end
      return
    end
    text = got["body_text"].to_s
    body = text.empty? ? nil : JSON.parse(text, max_nesting: false)
    if exp.key?("body")
      raise Fail, "#{where} body: expected #{short(exp['body'])}, got #{short(body)}" unless same?(exp["body"], body)
    elsif !exp.key?("body_checks") && !text.empty? && !exp["any_body"]
      raise Fail, "#{where} expected no body, got #{short(text)}"
    end
    (exp["body_checks"] || []).each { |check| check_value!(check, body, where) }
    (exp["ordered_keys"] || []).each do |ptr|
      _, want = pointer(exp["body"], ptr)
      order = ordered_keys_of(text, ptr)
      raise Fail, "#{where} body#{ptr}: key order expected #{want.keys}, got #{order}" unless order == want.keys
    end
  end

  def check_value!(check, body, where)
    ptr = check["pointer"]
    found, val = pointer(body, ptr)
    if check["absent"]
      raise Fail, "#{where} body#{ptr}: must be absent, got #{short(val)}" if found

      return
    end
    raise Fail, "#{where} body#{ptr}: missing" unless found
    if check.key?("equals") && !same?(check["equals"], val)
      raise Fail, "#{where} body#{ptr}: expected #{short(check['equals'])}, got #{short(val)}"
    end
    raise Fail, "#{where} body#{ptr}: expected a #{check['type']}" if check.key?("type") && !JSON_TYPES.fetch(check["type"]).(val)
    if check.key?("pattern") && !(val.is_a?(String) && val.match?(Regexp.new(check["pattern"])))
      raise Fail, "#{where} body#{ptr}: #{short(val)} does not match #{check['pattern']}"
    end
    return unless check.key?("keys") && (!val.is_a?(Hash) || val.keys != check["keys"])

    raise Fail, "#{where} body#{ptr}: keys expected #{check['keys']}, got #{val.is_a?(Hash) ? val.keys : val.inspect}"
  end

  # ---- responses

  def run_responses(case_)
    session = SecureRandom.hex(16)
    client = make_client({ "client" => { "api_key" => "dn_test_conformance" } },
                         "x-mock-session" => session, "x-mock-scenario" => "response/#{case_['id']}")
    result = invoke(client, case_["call"])
    exp = case_["expect"]
    if exp.key?("decision")
      match!(exp["decision"], norm_decision(result), "decision")
    elsif exp.key?("answer")
      match!(exp["answer"], norm_answer(result), "answer")
    elsif exp.key?("models")
      raise Fail, "models: expected ModelInfo entries" unless result.all?(DecisionNode::ModelInfo)

      # The fine-tuned fields are compared where the case lists them.
      got = result.each_with_index.map do |m, i|
        entry = { "name" => m.name, "description" => m.description, "release_date" => m.release_date, "limits" => m.limits }
        listed = exp["models"][i].is_a?(Hash) ? exp["models"][i] : {}
        %w[fine_tuned base adapter_version status].each { |k| entry[k] = m.public_send(k) if listed.key?(k) }
        entry
      end
      raise Fail, "models: expected #{short(exp['models'])}, got #{short(got)}" unless same?(exp["models"], got)
    elsif exp.key?("raw")
      raise Fail, "raw: expected #{short(exp['raw'])}, got #{short(result)}" unless same?(exp["raw"], result)
    elsif exp.key?("batch")
      raise Fail, "batch: expected a Batch, got #{result.class}" unless result.is_a?(DecisionNode::Batch)

      match!(exp["batch"], result.to_h, "batch")
    elsif exp.key?("batch_page")
      raise Fail, "batch_page: expected a BatchPage, got #{result.class}" unless result.is_a?(DecisionNode::BatchPage)

      match!(exp["batch_page"], result.to_h, "batch_page")
    elsif exp.key?("batch_results")
      check_batch_results!(exp["batch_results"], result, "batch_results")
    elsif exp.key?("session")
      match!(exp["session"], norm_session(result), "session")
    elsif exp.key?("upload_ids")
      raise Fail, "upload_ids: expected #{exp['upload_ids']}, got #{result}" unless same?(exp["upload_ids"], result.to_a)
    end
  end

  # ---- errors

  def run_errors(case_)
    session = SecureRandom.hex(16)
    client = make_client(case_, "x-mock-session" => session, "x-mock-scenario" => "error/#{case_['id']}")
    spec = case_["expect"]["error"]
    # catch_as is always the exported base name; the rescue below is written against it.
    if spec["catch_as"] && spec["catch_as"] != "DecisionNodeError"
      raise Fail, "catch_as #{spec['catch_as']} is not the base error's name"
    end

    begin
      invoke(client, case_["call"])
    rescue DecisionNode::DecisionNodeError => e
      check_error!(spec, e, "error")
    else
      raise Fail, "no error was raised"
    end
    log = mock_log(session)["requests"]
    raise Fail, "expected 1 attempt with max_retries 0, got #{log.size}" unless log.size == 1
  end

  # ---- behaviour

  def check_outcome!(spec, result, path)
    if result.is_a?(DecisionNode::SessionClosed) && !spec.key?("closed")
      raise Fail, "#{path}: the call raised SessionClosed(#{result.code})"
    end
    if spec["argument_error"]
      raise Fail, "#{path}: expected an ArgumentError, got #{result.class}: #{result}" unless result.is_a?(ArgumentError)

      return
    end
    raise Fail, "#{path}: unexpected argument error: #{result.message}" if result.is_a?(ArgumentError)

    if spec.key?("result")
      raise Fail, "#{path}: expected #{spec['result']}, got #{result.class}: #{result.message}" if result.is_a?(Exception)

      check_result!(spec, result, path)
    else
      raise Fail, "#{path}: expected #{spec['error']}, got a result" unless result.is_a?(DecisionNode::DecisionNodeError)

      check_error!(spec, result, path)
    end
  end

  def check_result!(spec, result, path)
    case spec["result"]
    when "decision"
      raise Fail, "#{path}: expected a Decision, got #{result.class}" unless result.is_a?(DecisionNode::Decision)

      match!(spec["decision"], norm_decision(result), "#{path}.decision") if spec.key?("decision")
    when "answer" then match!(spec.fetch("answer", {}), norm_answer(result), "#{path}.answer")
    when "batch"
      raise Fail, "#{path}: expected a Batch, got #{result.class}" unless result.is_a?(DecisionNode::Batch)

      match!(spec.fetch("batch", {}), result.to_h, "#{path}.batch")
    when "batch_page" then match!(spec.fetch("batch_page", {}), result.to_h, "#{path}.batch_page")
    when "batch_results" then check_results_spec!(spec, result, path)
    when "batch_run"
      batch, results = result
      match!(spec.fetch("batch", {}), batch.to_h, "#{path}.batch")
      check_results_spec!(spec, results, path)
    when "checked"
      raise Fail, "#{path}: the check returned #{result.inspect}; a request that passes returns nil" unless result.nil?
    when "session"
      raise Fail, "#{path}: expected a Session, got #{result.class}" unless result.is_a?(DecisionNode::Session)

      match!(spec.fetch("session", {}), norm_session(result), "#{path}.session")
    when "upload_ids"
      unless result.is_a?(Array) && result.size == spec.fetch("count", result.size)
        raise Fail, "#{path}: expected #{spec['count']} upload ids, got #{result.inspect}"
      end
      result.each { |id| raise Fail, "#{path}: #{id.inspect} is not an upload id" unless id.to_s.match?(/\Aupl_[0-9a-f]{32}\z/) }
      if !spec["distinct"].nil? && (result.uniq.size == result.size) != spec["distinct"]
        raise Fail, "#{path}: upload ids #{result}"
      end
    when "supervised"
      raise Fail, "#{path}: expected supervise to return" unless result.is_a?(Hash) && result["supervised"]

      replies = result["replies"].count { |e| e.is_a?(DecisionNode::Reply) }
      in_range!(spec.fetch("replies", {}), replies, "replies")
      if spec.key?("closed")
        closed = result["closed"]
        got = closed && { "code" => closed.code, "reopen" => closed.reopen }
        raise Fail, "#{path}.closed: expected #{spec['closed']}, got #{got.inspect}" unless same?(spec["closed"], got)
      end
    else
      raise Fail, "#{path}: unknown result kind #{spec['result']}"
    end
  end

  STEP_ERRORS = [DecisionNode::DecisionNodeError, ArgumentError, DecisionNode::SessionClosed].freeze

  def run_steps(case_, client, session, events)
    ctx = {}
    case_["steps"].each_with_index do |step, i|
      where = "steps[#{i}]"
      if step.key?("call")
        result = begin
          invoke(client, step["call"], ctx)
        rescue *STEP_ERRORS => e
          e
        end
        if step.key?("outcome")
          check_outcome!(step["outcome"], result, "#{where}.outcome")
        elsif result.is_a?(Exception)
          raise Fail, "#{where}: the call raised #{result.class}: #{result.message}"
        end
        ctx[step["save_as"]] = result if step.key?("save_as")
      elsif step.key?("connect")
        begin
          ctx.fetch(step["connect"]).connect
        rescue DecisionNode::SessionClosed => e
          # A refused handshake may surface here or as the first event: both count.
          events << norm_event(e)
        end
      elsif step.key?("send")
        args = step["send"].dup
        name = args.delete("session")
        frame = kwargs(args.transform_values { |v| decode(v, ctx) })
        begin
          result = step["check"] ? ctx.fetch(name).check_frame(**frame) : ctx.fetch(name).send(**frame)
        rescue DecisionNode::DecisionNodeError, ArgumentError => e
          # A frame that breaks a fixed rule is refused locally and nothing is sent.
          raise unless step.key?("outcome")

          check_outcome!(step["outcome"], e, "#{where}.outcome")
        else
          if step["check"] && step.key?("outcome")
            check_outcome!(step["outcome"], result, "#{where}.outcome")
          elsif step.key?("outcome")
            raise Fail, "#{where}: expected #{step['outcome']['error'] || step['outcome']}, the frame was sent"
          end
        end
      elsif step.key?("read")
        read_events(step["read"], ctx, events, where)
      elsif step.key?("end")
        begin
          ctx.fetch(step["end"]).end
          events << { "ended" => true }
        rescue DecisionNode::DecisionNodeError => e
          events << { "end_error" => { "class" => e.class.name.split("::").last, "status" => e.status } }
        end
      elsif step.key?("close")
        ctx.fetch(step["close"]).close
      elsif step.key?("mock_clock")
        mock_clock(session, step["mock_clock"])
      elsif step.key?("sleep_ms")
        sleep(step["sleep_ms"] / 1000.0)
      else
        raise Fail, "#{where}: unknown step #{step.keys}"
      end
    end
  end

  def read_events(spec, ctx, events, where)
    s = ctx.fetch(spec["session"])
    count = spec["count"]
    timeout = spec.fetch("timeout_ms", READ_TIMEOUT_MS) / 1000.0
    loop do
      event = s.next_event(timeout: timeout)
      raise Fail, "#{where}: no session event arrived in time (#{events.size} read so far)" if event.nil?

      events << norm_event(event)
      break if event.is_a?(DecisionNode::SessionClosed)
      next if count.nil?

      count -= 1
      break if count.zero?
    end
  end

  def check_sequence!(expected, log)
    got = describe(log)
    raise Fail, "request sequence: expected #{expected.size} requests, the mock received #{log.size}: #{got}" unless expected.size == log.size

    expected.zip(log).each_with_index do |(spec, rec), i|
      raise Fail, "request sequence[#{i}]: expected #{spec['method']}, got #{got[i]}" unless rec["method"] == spec["method"]
      if spec.key?("path") && rec["path"] != spec["path"]
        raise Fail, "request sequence[#{i}]: expected #{spec['method']} #{spec['path']}, got #{got[i]}"
      end
      if spec.key?("path_pattern") && !rec["path"].match?(Regexp.new(spec["path_pattern"]))
        raise Fail, "request sequence[#{i}]: #{got[i]} does not match #{spec['path_pattern']}"
      end
      if spec.key?("status") && rec["status"] != spec["status"]
        raise Fail, "request sequence[#{i}]: #{got[i]} answered #{rec['status']}, expected #{spec['status']}"
      end
      checks = spec.slice("headers", "header_patterns", "absent_headers", "body_checks", "jsonl_count", "jsonl_checks",
                          "body_base64", "body_sha256", "query")
      check_request!(checks.merge("method" => spec["method"], "any_body" => true), rec, "request sequence[#{i}]") unless checks.empty?
    end
  end

  def check_counts!(expected, log)
    expected.each do |spec|
      n = log.count do |r|
        r["method"] == spec["method"] && (!spec.key?("path") || r["path"] == spec["path"]) &&
          (!spec.key?("path_pattern") || r["path"].match?(Regexp.new(spec["path_pattern"])))
      end
      what = "#{spec['method']} #{spec['path'] || spec['path_pattern']}"
      raise Fail, "#{what}: expected #{spec['count']} requests, got #{n}" if spec.key?("count") && n != spec["count"]

      in_range!(spec.slice("min", "max"), n, what)
    end
  end

  def check_events!(expected, events)
    raise Fail, "session events: expected #{expected.size}, got #{events.size}: #{short(events)}" unless expected.size == events.size

    expected.zip(events).each_with_index do |(spec, event), i|
      raise Fail, "session events[#{i}]: expected #{spec.keys.first}, got #{short(event)}" unless spec.keys == event.keys

      key = spec.keys.first
      if spec[key].is_a?(Hash)
        match!(spec[key], event[key], "session events[#{i}].#{key}")
      elsif !same?(spec[key], event[key])
        raise Fail, "session events[#{i}]: expected #{short(spec)}, got #{short(event)}"
      end
    end
  end

  def run_behaviour(case_)
    session = SecureRandom.hex(16)
    extra = { "x-mock-session" => session }
    extra["x-mock-scenario"] = "behaviour/#{case_['id']}" if case_["mock"]
    exp = case_["expect"]
    waits = []
    events = []
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    result = begin
      # An argument error may come from the constructor (a bad base_url, timeout
      # or max_retries) or from the call; both count, as long as nothing was sent.
      client = make_client(case_, extra)
      # The SDK's injectable clock reads the mock's clock for this session.
      client.instance_variable_set(:@clock, -> { mock_clock_now(session) }) if case_.dig("client", "clock") == "mock"
      waits = record_waits(client) if exp.key?("scheduled_waits_ms")
      if case_.key?("steps")
        run_steps(case_, client, session, events)
        nil
      else
        invoke(client, case_["call"])
      end
    rescue DecisionNode::DecisionNodeError, ArgumentError => e
      e
    end
    elapsed = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000
    sleep 0.05 # let the mock finish recording dropped connections
    info = mock_log(session)
    log = info["requests"]
    if exp.key?("one_of")
      # The rule allows more than one way to comply; one of them must hold whole.
      reasons = exp["one_of"].each_with_index.filter_map do |alt, i|
        raise Fail, "attempts: expected #{alt['attempts']}, the mock received #{log.size}" unless log.size == alt["attempts"]

        check_outcome!(alt["outcome"], result, "outcome")
        nil
      rescue Fail => e
        "one_of[#{i}]: #{e.message}"
      end
      raise Fail, reasons.join("; ") if reasons.size == exp["one_of"].size
    elsif exp.key?("attempts") && log.size != exp["attempts"]
      raise Fail, "attempts: expected #{exp['attempts']}, the mock received #{log.size}: #{describe(log)}"
    end
    check_sequence!(exp["request_sequence"], log) if exp.key?("request_sequence")
    check_counts!(exp["request_counts"], log) if exp.key?("request_counts")
    check_events!(exp["session_events"], events) if exp.key?("session_events")
    in_range!(exp["pongs"], info["pongs"], "pongs") if exp.key?("pongs")
    check_outcome!(exp["outcome"], result, "outcome") if exp.key?("outcome")
    if exp.key?("results")
      unless result.is_a?(Array) && result.size == exp["results"].size
        raise Fail, "results: expected #{exp['results'].size} results, got #{result.inspect}"
      end

      exp["results"].zip(result).each_with_index do |(spec, res), i|
        raise Fail, "results[#{i}]: not a DecisionResult" unless res.is_a?(DecisionNode::DecisionResult)

        check_outcome!(spec, res, "results[#{i}]")
      end
    end
    if exp.key?("scheduled_waits_ms")
      want = exp["scheduled_waits_ms"]
      raise Fail, "scheduled waits: expected #{want.size}, got #{waits.size}: #{waits.inspect}" unless waits.size == want.size

      want.each_with_index { |range, i| in_range!(range, waits[i] * 1000, "wait #{i + 1} (ms)") }
    end
    raise Fail, "the steps raised #{result.class}: #{result.message}" if case_.key?("steps") && result.is_a?(Exception)

    (exp["unrequested_paths"] || []).each do |p|
      hits = mock_log("*", path: p)["requests"]
      raise Fail, "#{p} was requested #{hits.size} time(s)" unless hits.empty?
    end
    if exp.key?("gaps_ms")
      gaps = log.map { |r| r["time"] }.each_cons(2).map { |a, b| (b - a) * 1000 }
      exp["gaps_ms"].each_with_index { |range, i| in_range!(range, gaps[i], "gap #{i + 1} (ms)") }
    end
    in_range!(exp["elapsed_ms"], elapsed, "elapsed (ms)") if exp.key?("elapsed_ms")
    in_range!(exp["max_in_flight"], info["max_in_flight"], "max in flight") if exp.key?("max_in_flight")
  end

  # ---- constants

  def run_constants(case_)
    name = case_.dig("names", "ruby") || case_["constant"]
    raise Fail, "DecisionNode::#{name} is not defined" unless DecisionNode.const_defined?(name, false)

    value = DecisionNode.const_get(name, false)
    raise Fail, "#{name}: expected #{short(case_['equals'])}, got #{short(value)}" unless same?(case_["equals"], value)
  end
end

class ConformanceTest < Minitest::Test
  i_suck_and_my_tests_are_order_dependent! # cases set process environment variables; run one at a time

  def setup
    return if Conformance.available?
    flunk "DECISIONNODE_CONFORMANCE_DIR is not set; point it at a checkout of the conformance suite" if Conformance::ROOT.nil?

    flunk "conformance suite not found at #{Conformance::ROOT}"
  end

  def teardown
    Conformance::ENV_VARS.each { |v| ENV.delete(v) }
  end

  if Conformance.available?
    Conformance.cases.each do |kind, list|
      list.each do |c|
        define_method("test_#{kind}_#{c['id'].tr('-', '_')}") do
          Conformance.public_send("run_#{kind}", c)
          pass
        rescue Conformance::Fail => e
          flunk "#{kind}/#{c['id']}: #{e.message}"
        end
      end
    end
  else
    # setup fails this test, so a run without the suite never passes.
    define_method(:test_suite_present) { flunk "conformance suite missing" }
  end
end
