# frozen_string_literal: true

# Runs every case of the DecisionNode conformance suite against its mock server.
#
#   DECISIONNODE_CONFORMANCE_DIR=/path/to/decision-node-conformance bundle exec rake conformance
#
# The variable is required: when it is unset, or the suite is not found where it
# points, the tests fail. They are never skipped.

require "minitest/autorun"
require "json"
require "net/http"
require "securerandom"
require "decisionnode"

module Conformance
  ROOT = ENV.fetch("DECISIONNODE_CONFORMANCE_DIR", "").then { |dir| dir.empty? ? nil : File.expand_path(dir) }
  KINDS = %w[requests responses errors behaviour constants].freeze
  ENV_VARS = %w[DECISIONNODE_API_KEY DECISIONNODE_BASE_URL DECISIONNODE_MODEL].freeze
  EXACT = %w[probabilities legend raw entries safety body limits].freeze

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

  def mock_log(session, path: nil)
    query = { "session" => session }
    query["path"] = path if path
    uri = URI("#{mock_url}/_mock/requests?#{URI.encode_www_form(query)}")
    JSON.parse(Net::HTTP.get(uri))
  end

  # ---- comparison

  def same?(a, b)
    if [true, false].include?(a) || [true, false].include?(b)
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
    if expected.is_a?(Hash) && actual.is_a?(Hash)
      expected.each do |k, v|
        raise Fail, "#{path}.#{k}: missing (expected #{short(v)})" unless actual.key?(k)

        if EXACT.include?(k)
          raise Fail, "#{path}.#{k}: expected #{short(v)}, got #{short(actual[k])}" unless same?(v, actual[k])
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
    doc = JSON.parse(text, object_class: OrderedKeys)
    found, node = pointer(doc, ptr)
    found && node.is_a?(Hash) ? node.keys : []
  end

  class OrderedKeys < Hash; end

  # ---- normalisation into the neutral shapes the cases use

  def norm_answer(answer)
    case answer
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

  def norm_decision(decision)
    {
      "model" => decision.model,
      "request_id" => decision.request_id,
      "latency_ms" => decision.latency_ms,
      "usage" => { "input_tokens" => decision.usage.input_tokens, "output_tokens" => decision.usage.output_tokens },
      "safety" => decision.safety&.to_h,
      "answers" => decision.answers.transform_values { |a| norm_answer(a) },
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
      "retry_after" => get.(:retry_after)
    }
  end

  def check_error!(spec, err, path)
    cls = spec["error"] || spec["class"]
    names = err.class.ancestors.map { |c| c.name.to_s.split("::").last }
    if spec["subclass_ok"]
      raise Fail, "#{path}: expected #{cls} or a subclass, got #{err.class}" unless names.include?(cls)
    elsif err.class.name.split("::").last != cls
      raise Fail, "#{path}: expected #{cls}, got #{err.class} (#{err})"
    end
    match!(spec["fields"] || {}, norm_error(err), "#{path}.fields")
  end

  # ---- calls

  def decode(value)
    if value.is_a?(Hash) && value.size == 1
      key, args = value.first
      case key
      when "$truth" then return DecisionNode.truth(args["instructions"], if_true: args["true"], if_false: args["false"])
      when "$choice" then return DecisionNode.choice(args["instructions"], args["options"])
      when "$score" then return DecisionNode.score(args["instructions"], args["levels"])
      when "$image"
        return DecisionNode::Image.new(args["id"], path: File.join(ROOT, args["path"])) if args.key?("path")
        return DecisionNode::Image.new(args["id"], url: args["url"]) if args.key?("url")

        return DecisionNode::Image.new(args["id"], data: args["data_base64"].unpack1("m"),
                                                   media_type: args["media_type"])
      end
    end
    case value
    when Hash then value.transform_values { |v| decode(v) }
    when Array then value.map { |v| decode(v) }
    else value
    end
  end

  def invoke(client, call)
    method = call["method"]
    args = call["args"] || {}
    case method
    when "decide_raw" then client.decide_raw(args["body"])
    when "models" then client.models
    when "decide_many"
      kw = {}
      kw[:concurrency] = args["concurrency"] if args.key?("concurrency")
      client.decide_many(decode(args["requests"]), **kw)
    else
      kw = args.to_h do |k, v|
        name = { "true" => :if_true, "false" => :if_false }.fetch(k, k.to_sym)
        [name, decode(v)]
      end
      client.public_send(method, **kw)
    end
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
        return DecisionNode::HTTPResponse.new(res.code.to_i, res.to_hash.transform_values { |v| v.join(", ") }, res.body.to_s) unless res.is_a?(Net::HTTPRedirection)

        uri = URI.join(uri.to_s, res["location"])
      end
    end
  end

  def make_client(case_, extra_headers)
    ENV_VARS.each { |v| ENV.delete(v) }
    (case_["env"] || {}).each { |k, v| ENV[k] = fill(v) }
    spec = case_["client"] || {}
    kw = {}
    %w[api_key model timeout max_retries].each { |k| kw[k.to_sym] = spec[k] unless spec[k].nil? }
    if spec.key?("base_url")
      kw[:base_url] = fill(spec["base_url"]) unless spec["base_url"].nil?
    else
      kw[:base_url] = mock_url
    end
    kw[:headers] = (spec["headers"] || {}).merge(extra_headers)
    kw[:http_client] = FollowingTransport.new if spec["http_client"] == "caller_following_redirects"
    DecisionNode.new(**kw)
  end

  # ---- the four kinds

  def run_requests(case_)
    session = SecureRandom.hex(16)
    invoke(make_client(case_, "x-mock-session" => session), case_["call"])
    log = mock_log(session)["requests"]
    raise Fail, "expected 1 request, the mock received #{log.size}" unless log.size == 1

    got = log.first
    exp = case_["expect"]["request"]
    raise Fail, "method: expected #{exp['method']}, got #{got['method']}" unless got["method"] == exp["method"]
    raise Fail, "path: expected #{exp['path']}, got #{got['path']}" unless got["path"] == exp["path"]

    headers = got["headers"]
    (exp["headers"] || {}).each do |name, value|
      actual = headers[name.downcase]
      raise Fail, "header #{name}: expected #{value.inspect}, got #{actual.inspect}" unless actual == value
    end
    (exp["header_patterns"] || {}).each do |name, pattern|
      actual = headers[name.downcase]
      raise Fail, "header #{name}: #{actual.inspect} does not match #{pattern}" unless actual&.match?(Regexp.new(pattern))
    end
    (exp["absent_headers"] || []).each do |name|
      raise Fail, "header #{name} must not be sent" if headers.key?(name.downcase)
    end
    text = got["body_text"].to_s
    body = text.empty? ? nil : JSON.parse(text)
    if exp.key?("body")
      raise Fail, "body: expected #{short(exp['body'])}, got #{short(body)}" unless same?(exp["body"], body)
    elsif !exp.key?("body_checks") && !text.empty?
      raise Fail, "expected no body, got #{short(text)}"
    end
    (exp["body_checks"] || []).each do |check|
      ptr = check["pointer"]
      found, val = pointer(body, ptr)
      raise Fail, "body#{ptr}: missing" unless found
      if check.key?("equals") && !same?(check["equals"], val)
        raise Fail, "body#{ptr}: expected #{short(check['equals'])}, got #{short(val)}"
      end
      raise Fail, "body#{ptr}: expected a #{check['type']}" if check.key?("type") && !JSON_TYPES.fetch(check["type"]).(val)
      if check.key?("keys") && (!val.is_a?(Hash) || val.keys != check["keys"])
        raise Fail, "body#{ptr}: keys expected #{check['keys']}, got #{val.is_a?(Hash) ? val.keys : val.inspect}"
      end
    end
    (exp["ordered_keys"] || []).each do |ptr|
      _, want = pointer(exp["body"], ptr)
      order = ordered_keys_of(text, ptr)
      raise Fail, "body#{ptr}: key order expected #{want.keys}, got #{order}" unless order == want.keys
    end
  end

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

      got = result.map do |m|
        { "name" => m.name, "description" => m.description, "release_date" => m.release_date, "limits" => m.limits }
      end
      raise Fail, "models: expected #{short(exp['models'])}, got #{short(got)}" unless same?(exp["models"], got)
    elsif exp.key?("raw")
      raise Fail, "raw: expected #{short(exp['raw'])}, got #{short(result)}" unless same?(exp["raw"], result)
    end
  end

  def run_errors(case_)
    session = SecureRandom.hex(16)
    client = make_client(case_, "x-mock-session" => session, "x-mock-scenario" => "error/#{case_['id']}")
    spec = case_["expect"]["error"]
    # Caught through the exported name the case gives (catch_as), else the base class.
    catch_as = spec["catch_as"]
    unless catch_as.nil? || DecisionNode.const_defined?(catch_as, false)
      raise Fail, "DecisionNode::#{catch_as} is not defined"
    end

    rescue_class = DecisionNode.const_get(catch_as || "DecisionNodeError", false)
    begin
      invoke(client, case_["call"])
    rescue rescue_class => e
      check_error!(spec, e, "error")
    else
      raise Fail, "no error was raised"
    end
    log = mock_log(session)["requests"]
    raise Fail, "expected 1 attempt with max_retries 0, got #{log.size}" unless log.size == 1
  end

  def check_outcome!(spec, result, path)
    if spec["argument_error"]
      raise Fail, "#{path}: expected an ArgumentError, got #{result.class}: #{result}" unless result.is_a?(ArgumentError)
    elsif spec.key?("result")
      raise Fail, "#{path}: expected a decision, got #{result.class}: #{result}" if result.is_a?(Exception)

      match!(spec["decision"], norm_decision(result), "#{path}.decision") if spec.key?("decision")
    else
      raise Fail, "#{path}: expected #{spec['error']}, got a result" unless result.is_a?(DecisionNode::DecisionNodeError)

      check_error!(spec, result, path)
    end
  end

  def in_range!(range, value, what)
    raise Fail, format("%s %.0f is below %s", what, value, range["min"]) if range.key?("min") && value < range["min"]
    raise Fail, format("%s %.0f is above %s", what, value, range["max"]) if range.key?("max") && value > range["max"]
  end

  def run_behaviour(case_)
    session = SecureRandom.hex(16)
    extra = { "x-mock-session" => session }
    extra["x-mock-scenario"] = "behaviour/#{case_['id']}" if case_["mock"]
    exp = case_["expect"]
    waits = nil
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    result = begin
      # An argument error may come from the constructor (a bad base_url, timeout
      # or max_retries) or from the call; both count, as long as nothing was sent.
      client = make_client(case_, extra)
      waits = record_waits(client) if exp.key?("scheduled_waits_ms")
      invoke(client, case_["call"])
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
        unless log.size == alt["attempts"]
          raise Fail, "attempts: expected #{alt['attempts']}, the mock received #{log.size}"
        end

        check_outcome!(alt["outcome"], result, "outcome")
        nil
      rescue Fail => e
        "one_of[#{i}]: #{e.message}"
      end
      raise Fail, reasons.join("; ") if reasons.size == exp["one_of"].size
    elsif log.size != exp["attempts"]
      raise Fail, "attempts: expected #{exp['attempts']}, the mock received #{log.size}"
    end

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
      waits ||= []
      raise Fail, "scheduled waits: expected #{want.size}, got #{waits.size}" unless waits.size == want.size

      want.each_with_index { |range, i| in_range!(range, waits[i] * 1000, "wait #{i + 1} (ms)") }
    end
    (exp["unrequested_paths"] || []).each do |p|
      hits = mock_log("*", path: p)["requests"]
      raise Fail, "#{p} was requested #{hits.size} time(s)" unless hits.empty?
    end
    if exp.key?("gaps_ms")
      times = log.map { |r| r["time"] }
      gaps = times.each_cons(2).map { |a, b| (b - a) * 1000 }
      exp["gaps_ms"].each_with_index { |range, i| in_range!(range, gaps[i], "gap #{i + 1} (ms)") }
    end
    in_range!(exp["elapsed_ms"], elapsed, "elapsed (ms)") if exp.key?("elapsed_ms")
    in_range!(exp["max_in_flight"], info["max_in_flight"], "max in flight") if exp.key?("max_in_flight")
  end

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
