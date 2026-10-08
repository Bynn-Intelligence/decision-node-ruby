# frozen_string_literal: true

require "json"
require "time"
require "timeout"
require "uri"

class DecisionNode
  include Uploads

  DEFAULT_BASE_URL = "https://api.decisionnode.com"
  DEFAULT_MODEL = "decisionnode-latest"
  DEFAULT_TIMEOUT = 10.0
  DEFAULT_MAX_RETRIES = 2
  DEFAULT_CONCURRENCY = 8

  RETRY_STATUSES = ([408, 429] + (500..599).to_a).freeze
  BACKOFF_START = 0.5
  BACKOFF_CAP = 8.0
  # The longest wait between attempts the client accepts from the server, in seconds.
  RETRY_AFTER_CAP = 60.0

  # run_batch: the shortest wait between two reads of a running batch, the
  # default wait, and how long it waits for a batch to end, in seconds.
  MIN_POLL_INTERVAL = 10.0
  DEFAULT_POLL_INTERVAL = 60.0
  DEFAULT_BATCH_TIMEOUT = 26 * 3600.0

  # supervise: the backoff before connecting again, in seconds.
  RECONNECT_START = 1.0
  RECONNECT_CAP = 30.0

  # The client class under a second name.
  Client = self

  UNSET = Object.new.freeze
  private_constant :UNSET

  # The questions sent by #gate.
  GATE_QUESTIONS = {
    "risk" => Questions.score(
      "How much harm could this action cause if it is wrong?",
      %w[none low moderate high severe]
    ),
    "touches_production" => Questions.truth(
      "Does this action change a production system, production data or anything customers use?"
    ),
    "verdict" => Questions.choice(
      "Should this action run as it is, wait for a person to confirm it, or be blocked?",
      {
        "allow" => "safe to run without asking",
        "confirm" => "a person should confirm it first",
        "block" => "should not run"
      }
    )
  }.each_value { |q| q.each_value(&:freeze).freeze }.freeze

  attr_reader :base_url, :model, :timeout, :max_retries, :inline_threshold

  # The Batch API, a DecisionNode::Batches.
  attr_reader :batches

  # Every argument is optional.
  #
  # api_key::     the API key; else DECISIONNODE_API_KEY.
  # base_url::    else DECISIONNODE_BASE_URL, else https://api.decisionnode.com.
  # model::       the default model; else DECISIONNODE_MODEL, else decisionnode-latest.
  #
  # An empty string for api_key, base_url or model counts as not given.
  # The base URL must use https; http is accepted only for localhost,
  # 127.0.0.1 and ::1, so a key never travels unencrypted.
  # timeout::     seconds for a whole attempt, from sending the request to the
  #               last byte of the body (default 10). Must be above 0.
  # max_retries:: retries after the first attempt (default 2). Must be 0 or more.
  # headers::     extra headers sent with every API request and on a session's
  #               handshake (never on an image upload to storage).
  # inline_threshold:: bytes; a request's local images that total less go
  #               inline as base64, at or above it they are uploaded
  #               (default DEFAULT_INLINE_THRESHOLD, 524,288). 0 always uploads.
  # http_client:: a NetHTTPTransport built with your own options, or another
  #               transport with the interface of NetHTTPTransport#call.
  # logger::      a Logger; when given, each attempt is logged at debug level
  #               (method, path, status, request id and timing, never the body).
  #
  # A client is safe to share between threads and reuses its connections.
  def initialize(api_key: nil, base_url: nil, model: nil, timeout: nil, max_retries: nil,
                 headers: nil, inline_threshold: nil, http_client: nil, logger: nil)
    @api_key = given(api_key) || env("DECISIONNODE_API_KEY")
    @base_url = checked_base_url((given(base_url) || env("DECISIONNODE_BASE_URL") || DEFAULT_BASE_URL).chomp("/"))
    @model = given(model) || env("DECISIONNODE_MODEL") || DEFAULT_MODEL
    @timeout = timeout.nil? ? DEFAULT_TIMEOUT : checked_timeout(timeout)
    @max_retries = max_retries.nil? ? DEFAULT_MAX_RETRIES : checked_max_retries(max_retries)
    @inline_threshold = inline_threshold.nil? ? DEFAULT_INLINE_THRESHOLD : checked_threshold(inline_threshold)
    @headers = (headers || {}).to_h { |k, v| [k.to_s, v.to_s] }.freeze
    @http = checked_http_client(http_client) || NetHTTPTransport.new
    @logger = logger
    @sleeper = ->(seconds) { sleep(seconds) }
    @uploads = UploadCache.new
    @inflight = {}
    @inflight_lock = Mutex.new
    @batches = Batches.new(self)
  end

  def inspect
    "#<#{self.class.name} base_url=#{@base_url.inspect} model=#{@model.inspect}>"
  end

  # Sends one request and returns a Decision.
  #
  # state::     what is judged: a String or any JSON value (default "").
  # questions:: question id to question (a builder's result or a wire-form Hash).
  # images::    an Array of Image (or wire-form Hashes).
  # model::     overrides the client's model for this call (nil or "" uses the client's).
  #
  # The request is checked before anything is sent: a fault the API would
  # refuse raises BadRequestError or ValidationError with no request made.
  def decide(state: UNSET, questions: nil, images: nil, model: nil)
    decision_call("/v1/decide", state, questions, images, model).first
  end

  # Sends one request to `POST /v1/systemone`, the strict path, and returns a
  # Decision. It takes `truth`, `choice` and `score` questions; a truth question
  # is sent with the type name that path takes, and read back as a TruthAnswer.
  # The model is always sent.
  def systemone(state: UNSET, questions: nil, images: nil, model: nil)
    decision_call("/v1/systemone", state, questions, images, model, strict: true).first
  end

  # Runs several #decide calls, at most `concurrency` at a time. Each request is
  # a Hash of #decide's arguments. Returns one entry per request, in input
  # order: a Decision, or the error that request ended with. One failure does
  # not stop the others. Each entry is a DecisionResult.
  #
  # Every request is checked before any is sent: a concurrency below 1 or a
  # request #decide would refuse as an argument raises ArgumentError, and a
  # request the API would refuse raises its BadRequestError or ValidationError,
  # with nothing sent. Images uploaded for one request are reused by the others.
  def decide_many(requests, concurrency: DEFAULT_CONCURRENCY)
    limit = begin
      Integer(concurrency)
    rescue TypeError, FloatDomainError
      raise ArgumentError, "concurrency must be a whole number of at least 1, got #{concurrency.inspect}"
    end
    raise ArgumentError, "concurrency must be at least 1, got #{limit}" if limit < 1
    raise ArgumentError, "requests must be an Array of Hashes of decide's arguments" unless requests.respond_to?(:to_a)

    calls = requests.to_a.each_with_index.map do |item, i|
      prepared_call(**decide_args(item))
    rescue ArgumentError => e
      raise ArgumentError, "decide_many: request #{i}: #{e.message}"
    end
    results = Array.new(calls.size)
    return results if calls.empty?

    queue = Queue.new
    calls.each_index { |i| queue << i }
    workers = Array.new([limit, calls.size].min) do
      Thread.new do
        loop do
          i = begin
            queue.pop(true)
          rescue ThreadError
            break
          end
          results[i] = result_for { send_prepared("/v1/decide", calls[i]).first }
        end
      end
    end
    workers.each(&:join)
    results
  end

  # Asks one `truth` question (id "check") and returns its TruthAnswer.
  # An answer that is missing or malformed raises ServerError, since a
  # TruthAnswer is promised; #decide would return an UnknownAnswer instead.
  def check(state: UNSET, instructions: nil, if_true: nil, if_false: nil, images: nil, model: nil)
    question = Questions.truth(instructions, if_true: if_true, if_false: if_false)
    helper_answer("check", TruthAnswer, state, question, images, model)
  end

  # Asks one `choice` question (id "classify") and returns its ChoiceAnswer.
  # An answer that is missing or malformed raises ServerError.
  def classify(state: UNSET, instructions: nil, options: nil, images: nil, model: nil)
    helper_answer("classify", ChoiceAnswer, state, Questions.choice(instructions, options), images, model)
  end

  # Asks one `score` question (id "score") and returns its ScoreAnswer.
  # An answer that is missing or malformed raises ServerError.
  def score(state: UNSET, instructions: nil, levels: nil, images: nil, model: nil)
    helper_answer("score", ScoreAnswer, state, Questions.score(instructions, levels), images, model)
  end

  # Asks one `number` question (id "number") and returns its NumberAnswer.
  # `min`, `max` and `step` left out take the server's defaults (0, 255, 1).
  # An answer that is missing or malformed raises ServerError.
  def number(state: UNSET, instructions: nil, min: nil, max: nil, step: nil, images: nil, model: nil)
    question = Questions.number(instructions, min: min, max: max, step: step)
    helper_answer("number", NumberAnswer, state, question, images, model)
  end

  # Judges an action before it runs. Sends three questions: "risk" (score),
  # "touches_production" (truth) and "verdict" (choice of allow, confirm or block).
  def gate(action:, context: nil, images: nil, model: nil)
    state = { "action" => action }
    state["context"] = context unless context.nil?
    decide(state: state, questions: GATE_QUESTIONS, images: images, model: model)
  end

  # Lists the models with their published limits, as ModelInfo entries.
  def models
    body, = request("GET", "/v1/models", nil)
    list = body.is_a?(Hash) ? body["models"] : nil
    (list || []).map { |m| ModelInfo.new(m) }
  end

  # Sends `body` to POST /v1/decide exactly as given and returns the parsed
  # response body. Use it for API fields this version does not know yet.
  # Nothing is checked and no image is uploaded.
  def decide_raw(body)
    parsed, = request("POST", "/v1/decide", body)
    parsed
  end

  # Opens a session (`POST /v1/sessions`) and returns a Session: one state and
  # a fixed set of questions, answered again for every frame sent on its
  # socket. Only the arguments given are sent, and `model` always is.
  #
  # A 429 `session_limit_exceeded` (the key holds its most open sessions) is
  # never retried and raises SessionLimitError, a RateLimitError.
  def open_session(questions:, state: nil, instructions: nil, model: nil, window: nil, ttl_seconds: nil)
    qs = prepared_questions(questions)
    body = { "model" => given(model) || @model }
    body["instructions"] = instructions unless instructions.nil?
    body["state"] = state unless state.nil?
    body["questions"] = qs
    body["window"] = window unless window.nil?
    body["ttl_seconds"] = ttl_seconds unless ttl_seconds.nil?
    raw, = request("POST", "/v1/sessions", encode(body), encoded: true, policy: :session_open)
    Session.new(self, raw)
  end

  # Runs one long-lived feed through sessions, reopening them as the close
  # codes say, and hands every Reply and FrameError to `on_reply` (or the
  # block). Latest wins: each reading is sent as it comes, never queued
  # behind an unanswered one.
  #
  # body::     open_session's arguments, as a Hash.
  # feed::     an Enumerable of readings, each a Hash of Session#send's arguments.
  #
  # A session closed with 1001, 1006, 1011, 4404, 4408, 4409 or 4410 is
  # reopened with the same body before the next reading (after a capped backoff
  # with jitter, 1 s to 30 s, except after 4408 and 4410); 1013 connects again
  # to the same session after the backoff; any other code stops it. When the
  # feed ends it waits for the outstanding replies, ends the session and
  # returns the last SessionClosed, or nil when none was seen; when it stops on
  # a code it returns that SessionClosed.
  def supervise(body, feed, on_reply = nil, max_sessions: 10, drain_timeout: 3.0, &block)
    handler = on_reply || block
    raise ArgumentError, "supervise needs on_reply or a block" if handler.nil?
    raise ArgumentError, "body must be a Hash of open_session's arguments" unless body.is_a?(Hash)

    Supervisor.new(self, body.to_h { |k, v| [k.to_sym, v] }, handler, max_sessions, drain_timeout).run(feed)
  end

  # Runs a whole batch and returns `[batch, results]`: the ended Batch and one
  # BatchResult per request. Creates an empty draft, adds the requests (in
  # calls of at most 10 MiB), finalizes it, then reads it every `poll_interval`
  # seconds (or the server's Retry-After when longer) until it ends, and reads
  # its results. If an add fails, the draft is cancelled and the error raised.
  #
  # poll_interval:: seconds, at least 10 (default 60).
  # timeout::       seconds to wait for the batch to end (default 26 hours);
  #                 past it TimeoutError is raised and the batch keeps running.
  def run_batch(requests, poll_interval: DEFAULT_POLL_INTERVAL, timeout: DEFAULT_BATCH_TIMEOUT)
    interval = checked_seconds(poll_interval, "poll_interval")
    raise ArgumentError, "poll_interval must be at least #{MIN_POLL_INTERVAL.to_i} seconds" if interval < MIN_POLL_INTERVAL

    limit = checked_seconds(timeout, "timeout")
    raise ArgumentError, "requests must be an Array of Hashes" unless requests.respond_to?(:to_a)

    list = requests.to_a
    list.each_with_index { |req, i| checked_line(req, i) }
    draft = @batches.create([])
    begin
      @batches.add(draft.id, list) unless list.empty?
    rescue StandardError
      begin
        @batches.cancel(draft.id)
      rescue DecisionNodeError
        nil
      end
      raise
    end
    batch = @batches.finalize(draft.id)
    headers = {}
    waited = 0.0
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    until batch.ended?
      elapsed = [waited, Process.clock_gettime(Process::CLOCK_MONOTONIC) - started].max
      raise TimeoutError, "the batch #{batch.id} did not end within #{limit} s" if elapsed >= limit

      server = retry_wait(headers)
      wait = server && server > interval ? server : interval
      @sleeper.call(wait)
      waited += wait
      batch, headers = @batches.get_with_headers(batch.id)
    end
    [batch, @batches.results(batch.id)]
  end

  # Closes idle connections.
  def close
    @http.close if @http.respond_to?(:close)
  end

  private

  LOOPBACK_HOSTS = %w[localhost 127.0.0.1 ::1].freeze
  private_constant :LOOPBACK_HOSTS

  # Raised inside an attempt when its whole-attempt deadline passes.
  # An Exception, not a StandardError, so a transport's own rescue does not swallow it.
  class AttemptDeadline < Exception; end
  private_constant :AttemptDeadline

  # A request checked and ready to send: the parts of its body, with its
  # images still to be placed (inline or uploaded) when it is sent.
  Prepared = Struct.new(:state, :questions, :images, :model, :encoded)
  private_constant :Prepared

  def checked_base_url(url)
    uri = begin
      URI.parse(url)
    rescue URI::InvalidURIError => e
      raise ArgumentError, "base_url is not a valid URL: #{e.message}"
    end
    host = uri.host.to_s.delete_prefix("[").delete_suffix("]").downcase
    raise ArgumentError, "base_url must be an absolute URL with a host, got #{url.inspect}" if host.empty?

    case uri.scheme&.downcase
    when "https" then url
    when "http"
      return url if LOOPBACK_HOSTS.include?(host)

      raise ArgumentError, "base_url must use https (http is accepted only for localhost, 127.0.0.1 and ::1), " \
                           "got #{url.inspect}"
    else
      raise ArgumentError, "base_url must use https, got #{url.inspect}"
    end
  end

  def checked_timeout(value)
    seconds = Float(value)
    raise ArgumentError, "timeout must be above 0 seconds, got #{value.inspect}" unless seconds.positive? && seconds.finite?

    seconds
  rescue TypeError
    raise ArgumentError, "timeout must be a number of seconds, got #{value.inspect}"
  end

  def checked_seconds(value, name)
    raise ArgumentError, "#{name} must be a number of seconds, got #{value.inspect}" unless value.is_a?(Numeric)

    seconds = value.to_f
    raise ArgumentError, "#{name} must be a finite number above 0, got #{value.inspect}" unless seconds.positive? && seconds.finite?

    seconds
  end

  def checked_max_retries(value)
    count = value.is_a?(Float) && value != value.floor ? nil : Integer(value)
    raise ArgumentError, "max_retries must be a whole number of 0 or more, got #{value.inspect}" if count.nil? || count.negative?

    count
  rescue TypeError, FloatDomainError
    raise ArgumentError, "max_retries must be a whole number of 0 or more, got #{value.inspect}"
  end

  def checked_threshold(value)
    unless value.is_a?(Integer) && !value.negative?
      raise ArgumentError, "inline_threshold must be a whole number of bytes, 0 or more, got #{value.inspect}"
    end

    value
  end

  # A transport passed in must never follow a redirect, so the key is never
  # sent to another URL. It says so by answering false to follow_redirects?;
  # one that answers true, or does not answer, is refused.
  def checked_http_client(http)
    return nil if http.nil?
    raise ArgumentError, "http_client must respond to call(method, url, headers, body, timeout)" unless http.respond_to?(:call)

    unless http.respond_to?(:follow_redirects?) && http.follow_redirects? == false
      raise ArgumentError, "http_client must never follow redirects and say so: follow_redirects? must return false"
    end

    http
  end

  # A value counts as given unless it is nil or an empty string.
  def given(value)
    return nil if value.nil?

    text = value.to_s
    text.empty? ? nil : text
  end

  def env(name)
    value = ENV.fetch(name, nil)
    value.nil? || value.empty? ? nil : value
  end

  DECIDE_ARGS = %i[state questions images model].freeze
  private_constant :DECIDE_ARGS

  def decide_args(item)
    raise ArgumentError, "each request must be a Hash of decide's arguments, got #{item.class}" unless item.is_a?(Hash)

    args = item.to_h { |k, v| [k.to_sym, v] }
    unknown = args.keys - DECIDE_ARGS
    raise ArgumentError, "unknown argument(s) #{unknown.join(', ')}; decide takes #{DECIDE_ARGS.join(', ')}" unless unknown.empty?

    args
  end

  # The question map with String ids and String top-level keys in each
  # question, checked against the API's fixed rules.
  def prepared_questions(questions)
    if questions.nil? || !questions.respond_to?(:each_pair) || questions.empty?
      raise ArgumentError, "questions must hold at least one question"
    end

    map = questions.each_pair.to_h do |id, q|
      raise ArgumentError, "question #{id.to_s.inspect} must be a Hash, got #{q.class}" unless q.is_a?(Hash)

      [id.to_s, q.keys.all?(String) ? q : q.transform_keys(&:to_s)]
    end
    Checks.questions!(map)
    map
  end

  # The image list, checked: at most 4, unique ids, each image's own rules.
  def prepared_images(images)
    return [] if images.nil?
    raise ArgumentError, "images must be an Array of DecisionNode::Image" unless images.is_a?(Array)

    images.each do |img|
      next if img.is_a?(Image) || img.is_a?(Hash)

      raise ArgumentError, "each image must be a DecisionNode::Image or a wire-form Hash, got #{img.class}"
    end
    Checks.images!(images)
    images
  end

  # Checks a request and keeps what is needed to send it. A request without
  # local images is encoded once here.
  def prepared_call(state: UNSET, questions: nil, images: nil, model: nil, strict: false)
    qs = prepared_questions(questions)
    qs = strict_questions(qs) if strict
    imgs = prepared_images(images)
    state = state.equal?(UNSET) || state.nil? ? "" : state
    model = given(model) || @model
    if imgs.any? { |img| img.is_a?(Image) && img.local? }
      encode(body_for(model, state, qs, nil)) # a value that cannot be serialised fails here
      Prepared.new(state, qs, imgs, model, nil)
    else
      wires = imgs.empty? ? nil : imgs.map { |img| img.is_a?(Image) ? img.to_h : img }
      Prepared.new(state, qs, imgs, model, encode(body_for(model, state, qs, wires)))
    end
  end

  def body_for(model, state, questions, images)
    body = { "model" => model, "state" => state, "questions" => questions }
    body["images"] = images unless images.nil?
    body
  end

  def decision_call(path, state, questions, images, model, strict: false)
    send_prepared(path, prepared_call(state: state, questions: questions, images: images, model: model, strict: strict))
  end

  # /v1/systemone takes the truth type under its own wire name.
  def strict_questions(questions)
    questions.transform_values { |q| q["type"] == "truth" ? q.merge("type" => TruthAnswer::STRICT_TYPE) : q }
  end

  # Sends a prepared request; returns the Decision and the HTTP status. A
  # request that named uploads the SDK placed, answered with a stale-upload
  # 400, is sent once more with the images uploaded again (not a retry).
  def send_prepared(path, call)
    if call.encoded
      body, headers, status = request("POST", path, call.encoded, encoded: true)
      return [Decision.new(body, headers), status]
    end

    2.times do |attempt|
      wires, placed = image_wires(call.images)
      data = encode(body_for(call.model, call.state, call.questions, wires.empty? ? nil : wires))
      begin
        body, headers, status = request("POST", path, data, encoded: true)
        return [Decision.new(body, headers), status]
      rescue BadRequestError => e
        raise unless attempt.zero? && !placed.empty? && STALE_UPLOAD.include?(e.error_type)

        @uploads.drop(placed)
      end
    end
  end

  # The typed answer a helper promises, or a ServerError when it is missing
  # or malformed.
  def helper_answer(id, klass, state, question, images, model)
    decision, status = decision_call("/v1/decide", state, { id => question }, images, model)
    answer = decision.answers[id]
    return answer if answer.is_a?(klass)

    what = answer.nil? ? "has no answer" : "has a malformed answer"
    raise ServerError.new("the response #{what} to the #{id.inspect} question",
                          status: status, request_id: decision.request_id,
                          reason: decision.headers["x-decisionnode-error"],
                          body: decision.raw, headers: decision.headers)
  end

  # One entry of #decide_many: a Decision or a DecisionNodeError. An error of
  # any other class is wrapped, with the original as its cause.
  def result_for
    yield
  rescue DecisionNodeError => e
    e
  rescue StandardError => e
    begin
      raise DecisionNodeError, "the request failed: #{e.message} (#{e.class})"
    rescue DecisionNodeError => wrapped
      wrapped
    end
  end

  # ---- sessions

  # Waits between attempts, polls and reconnects; tests replace @sleeper.
  def pause(seconds)
    @sleeper.call(seconds)
  end

  # The `image` of a session frame: inline under the threshold, else by
  # upload id; a URL is refused, since frames take bytes or an upload.
  def frame_image(image)
    return image if image.is_a?(Hash)
    raise ArgumentError, "image must be a DecisionNode::Image, got #{image.class}" unless image.is_a?(Image)
    if image.url
      raise BadRequestError.new("A frame's image takes bytes or an upload, not a url.", error_type: "api_usage_error")
    end

    Checks.images!([image])
    wires, = image_wires([image])
    wires.first.reject { |k, _| k == "id" }
  end

  def session_stream(url)
    raise AuthenticationError, "no API key: pass api_key: or set DECISIONNODE_API_KEY" if @api_key.nil?
    raise ArgumentError, "the session has no stream_url" if url.nil?

    headers = { "Authorization" => "Bearer #{@api_key}", "User-Agent" => "decisionnode-ruby/#{VERSION}" }
    SessionStream.new(url, headers.merge(@headers), @timeout)
  end

  # ---- batches

  def line_parts(req, index)
    raise ArgumentError, "batch request #{index} must be a Hash, got #{req.class}" unless req.is_a?(Hash)

    args = req.to_h { |k, v| [k.to_s, v] }
    raise ArgumentError, "batch request #{index} needs a custom_id" if args["custom_id"].nil?

    [args, prepared_questions(args["questions"]), prepared_images(args["images"])]
  rescue ArgumentError => e
    raise e if e.message.start_with?("batch request")

    raise ArgumentError, "batch request #{index}: #{e.message}"
  end

  def checked_line(req, index)
    line_parts(req, index)
    nil
  end

  # One JSON Lines line: custom_id, model (always), state ("" when absent),
  # questions, images, then any other field as given.
  def batch_line(req, index)
    args, questions, images = line_parts(req, index)
    line = { "custom_id" => args["custom_id"], "model" => given(args["model"]) || @model,
             "state" => args["state"].nil? ? "" : args["state"], "questions" => questions }
    line["images"] = image_wires(images).first unless images.empty?
    args.each { |k, v| line[k] = v unless line.key?(k) || k == "images" }
    "#{encode(line)}\n"
  end

  # ---- transport

  def encode(body)
    JSON.generate(body)
  rescue JSON::GeneratorError, Encoding::UndefinedConversionError, SystemStackError => e
    raise ArgumentError, "the request cannot be serialised as JSON: #{e.message}"
  end

  # Sends one API request with the retry policy and returns the parsed body
  # (or the text with raw: true), the response headers and the status.
  #
  # policy:: :default retries 408, 429, 5xx, timeouts and connection errors;
  #          :mutation (batch create, add, finalize) only 429 and 529;
  #          :session_open never a 429 `session_limit_exceeded`.
  def request(method, path, body, encoded: false, policy: :default, content_type: nil, raw: false)
    raise AuthenticationError, "no API key: pass api_key: or set DECISIONNODE_API_KEY" if @api_key.nil?

    data = body.nil? || encoded ? body : encode(body)
    headers = {
      "Authorization" => "Bearer #{@api_key}",
      "User-Agent" => "decisionnode-ruby/#{VERSION}",
      "Accept" => "application/json"
    }
    headers["Content-Type"] = content_type || "application/json" unless data.nil?
    headers.merge!(@headers)
    url = @base_url + path

    attempt = 0
    loop do
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      begin
        response = attempt_once(method, url, headers, data)
      rescue TimeoutError, ConnectionError => e
        log(method, path, e.class.name.split("::").last, nil, started, attempt)
        raise if attempt >= @max_retries || policy == :mutation

        @sleeper.call(backoff(attempt))
        attempt += 1
        next
      end
      log(method, path, response.status, response.headers["x-request-id"], started, attempt)

      # Only 2xx is a success. Redirects are never followed, so the key is
      # never sent to another URL or over plain HTTP: a 3xx is an error.
      if (200..299).cover?(response.status)
        return [response.body.to_s, response.headers, response.status] if raw

        return [parse_success(response), response.headers, response.status]
      end

      error = error_for(response)
      if attempt < @max_retries && retryable?(error, policy)
        wait = retry_wait(response.headers)
        @sleeper.call(wait.nil? ? backoff(attempt) : wait)
        attempt += 1
        next
      end
      raise error
    end
  end

  def retryable?(error, policy)
    case policy
    when :mutation then [429, 529].include?(error.status)
    when :session_open then RETRY_STATUSES.include?(error.status) && !error.is_a?(SessionLimitError)
    else RETRY_STATUSES.include?(error.status)
    end
  end

  # One attempt under one deadline: the timeout covers the whole attempt, from
  # sending the request to the last byte of the body, whatever the transport
  # does in between.
  def attempt_once(method, url, headers, data)
    response = begin
      Timeout.timeout(@timeout, AttemptDeadline) { @http.call(method, url, headers, data, @timeout) }
    rescue AttemptDeadline
      raise TimeoutError, "no complete response within #{@timeout} s"
    end
    unless response.is_a?(HTTPResponse)
      raise ConnectionError, "the transport returned #{response.class}, not a DecisionNode::HTTPResponse"
    end
    # A transport that followed a redirect reports the address it ended at.
    if response.url && response.url != url
      raise DecisionNodeError.new("the transport followed a redirect to another URL; redirects are never followed",
                                  status: response.status, headers: response.headers)
    end
    response
  end

  def parse_success(response)
    JSON.parse(response.body)
  rescue JSON::ParserError, TypeError => e
    raise ServerError.new("the response is not JSON: #{e.message}",
                          status: response.status, request_id: response.headers["x-request-id"],
                          headers: response.headers)
  end

  def backoff(attempt)
    base = [BACKOFF_CAP, BACKOFF_START * (2**attempt)].min
    base * (0.75 + (rand * 0.25))
  end

  # The wait the server asks for, in seconds: retry-after-ms, else Retry-After
  # in seconds or as an HTTP date. Capped at RETRY_AFTER_CAP; nil when neither
  # header holds a usable value.
  def retry_wait(headers)
    ms = number_value(headers["retry-after-ms"])
    seconds = ms.nil? ? nil : ms / 1000.0
    seconds ||= number_value(headers["retry-after"]) || http_date_wait(headers["retry-after"])
    return nil if seconds.nil? || seconds.nan?

    seconds.clamp(0.0, RETRY_AFTER_CAP)
  end

  def http_date_wait(value)
    return nil if value.nil?

    Time.httpdate(value.strip) - Time.now
  rescue ArgumentError
    nil
  end

  def number_value(value)
    value.nil? ? nil : Float(value.strip)
  rescue ArgumentError
    nil
  end

  def error_for(response)
    body = begin
      JSON.parse(response.body.to_s)
    rescue JSON::ParserError
      nil
    end
    error_from(response.status, response.headers, body)
  end

  # The error the API's answer gives: the class by status (and error_type),
  # with the fields read from the body and headers.
  def error_from(status, headers, body)
    detail = body.is_a?(Hash) ? body["detail"] : nil
    message = error_type = entries = category = nil
    case detail
    when Hash
      error_type = detail["error_type"]
      message = detail["message"]
      category = detail["category"]
    when String
      message = detail
    when Array
      entries = detail
    end
    kw = {
      status: status, error_type: error_type, request_id: headers["x-request-id"],
      reason: headers["x-decisionnode-error"], body: body, headers: headers
    }

    case status
    when 400
      error_type == "max_tokens_exceeded" ? ContextLimitError.new(message, **kw) : BadRequestError.new(message, **kw)
    when 401 then AuthenticationError.new(message, **kw)
    when 402 then InsufficientCreditError.new(message, **kw)
    when 403
      if error_type == "refusal_error"
        RefusalError.new(message, category: category, safety: Safety.parse(headers["x-decisionnode-safety"]), **kw)
      else
        PermissionDeniedError.new(message, **kw)
      end
    when 404 then NotFoundError.new(message, **kw)
    when 422 then ValidationError.new(message, entries: entries, **kw)
    when 429
      klass = error_type == "session_limit_exceeded" ? SessionLimitError : RateLimitError
      klass.new(message, retry_after: retry_wait(headers), **kw)
    when 529 then OverloadedError.new(message, retry_after: retry_wait(headers), **kw)
    when 500..599 then ServerError.new(message, **kw)
    # Every other status, 3xx included: the base class with the status.
    else DecisionNodeError.new(message, **kw)
    end
  end

  def log(method, path, status, request_id, started, attempt)
    return unless @logger

    ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round
    @logger.debug("decisionnode: #{method} #{path} -> #{status} request_id=#{request_id || '-'} " \
                  "#{ms} ms attempt=#{attempt + 1}")
  end
end
