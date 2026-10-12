# frozen_string_literal: true

require "json"
require "time"
require "timeout"
require "uri"

class DecisionNode
  include Uploads

  DEFAULT_BASE_URL = "https://api.decisionnode.com"
  DEFAULT_MODEL = "decisionnode-moe"
  DEFAULT_TIMEOUT = 10.0
  DEFAULT_MAX_RETRIES = 2
  DEFAULT_CONCURRENCY = 8
  # Seconds for one image PUT to storage, apart from `timeout`: a 10 MB image
  # on a slow uplink needs more than an API call does.
  DEFAULT_UPLOAD_TIMEOUT = 60.0
  # Seconds for one attempt of a decision whose boosters name ocr, when the
  # caller set no timeout: reading text takes longer than a decision does.
  OCR_TIMEOUT = 30.0
  private_constant :OCR_TIMEOUT

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

  attr_reader :base_url, :model, :timeout, :max_retries, :inline_threshold, :upload_timeout

  # The Batch API, a DecisionNode::Batches.
  attr_reader :batches

  # Collections of faces, a DecisionNode::Collections.
  attr_reader :collections

  # Every argument is optional.
  #
  # api_key::     the API key; else DECISIONNODE_API_KEY.
  # base_url::    else DECISIONNODE_BASE_URL, else https://api.decisionnode.com.
  # model::       the default model; else DECISIONNODE_MODEL, else decisionnode-moe.
  #
  # An empty string for api_key, base_url or model counts as not given.
  # The base URL must use https; http is accepted only for localhost,
  # 127.0.0.1 and ::1, so a key never travels unencrypted.
  # timeout::     seconds for a whole attempt, from sending the request to the
  #               last byte of the body (default 10, and 30 for a decision whose
  #               boosters name ocr; a timeout given here is used as given for
  #               every call). Must be above 0.
  # max_retries:: retries after the first attempt (default 2). Must be 0 or more.
  # headers::     extra headers sent with every API request and on a session's
  #               handshake (never on an image upload to storage).
  # inline_threshold:: bytes; a request's local images that total less go
  #               inline as base64, at or above it they are uploaded
  #               (default DEFAULT_INLINE_THRESHOLD, 524,288). 0 always uploads.
  # upload_timeout:: seconds for one image PUT to storage (default 60), apart
  #               from `timeout`. Must be above 0.
  # http_client:: a NetHTTPTransport built with your own options, or another
  #               transport with the interface of NetHTTPTransport#call.
  # logger::      a Logger; when given, each attempt is logged at debug level
  #               (method, path, status, request id and timing, never the body).
  #
  # A client is safe to share between threads and reuses its connections.
  def initialize(api_key: nil, base_url: nil, model: nil, timeout: nil, max_retries: nil,
                 headers: nil, inline_threshold: nil, upload_timeout: nil, http_client: nil, logger: nil)
    @api_key = given(api_key) || env("DECISIONNODE_API_KEY")
    @base_url = checked_base_url((given(base_url) || env("DECISIONNODE_BASE_URL") || DEFAULT_BASE_URL).chomp("/"))
    @model = given(model) || env("DECISIONNODE_MODEL") || DEFAULT_MODEL
    @timeout = timeout.nil? ? DEFAULT_TIMEOUT : checked_timeout(timeout)
    @timeout_given = !timeout.nil?
    @max_retries = max_retries.nil? ? DEFAULT_MAX_RETRIES : checked_max_retries(max_retries)
    @inline_threshold = inline_threshold.nil? ? DEFAULT_INLINE_THRESHOLD : checked_threshold(inline_threshold)
    @upload_timeout = upload_timeout.nil? ? DEFAULT_UPLOAD_TIMEOUT : checked_timeout(upload_timeout, "upload_timeout")
    @headers = (headers || {}).to_h { |k, v| [k.to_s, v.to_s] }.freeze
    @http = checked_http_client(http_client) || NetHTTPTransport.new
    @logger = logger
    @sleeper = ->(seconds) { sleep(seconds) }
    @clock = -> { Time.now.to_f }
    @uploads = UploadCache.new(clock: -> { @clock.call })
    @held = {}
    @inflight = {}
    @inflight_lock = Mutex.new
    @batches = Batches.new(self)
    @collections = Collections.new(self)
  end

  def inspect
    "#<#{self.class.name} base_url=#{@base_url.inspect} model=#{@model.inspect}>"
  end

  # Sends one request and returns a Decision.
  #
  # state::     what is judged: a String or any JSON value (default "").
  # questions:: question id to question (a builder's result or a wire-form Hash).
  # images::    an Array of Image (or wire-form Hashes), up to 16.
  # videos::    an Array of Video (or wire-form Hashes), up to 4, each sent as
  #             its frames.
  # model::     overrides the client's model for this call (nil or "" uses the
  #             client's). A fine-tuned model's name ("decisionnode-moe@acme/fraud",
  #             or pinned, ".../fraud:3") is sent as given.
  # boosters::  an Array of boosters that read the request's images before the
  #             decision: names ("age"), Booster objects or wire-form Hashes, sent
  #             in this order. Their readings come back in Decision#evidence.
  # fallback::  true or false, sent only when given. Left out, the API's default
  #             (true) applies: a decisionnode-moe request that no ready
  #             worker can take at once is answered by Flash, and
  #             Decision#fallback names both by their pinned ids. false: such a request gets the 529
  #             OverloadedError instead, retried like every 529.
  #
  # The request is checked before anything is sent: a fault the API would
  # refuse raises BadRequestError or ValidationError with no request made.
  # Boosters are not checked locally: the API answers for them.
  def decide(state: UNSET, questions: nil, images: nil, videos: nil, model: nil, boosters: nil, fallback: nil)
    decision_call("/v1/decide", state, questions, images, videos, model, boosters, fallback).first
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
  def check(state: UNSET, instructions: nil, if_true: nil, if_false: nil, images: nil, videos: nil, model: nil,
            boosters: nil, fallback: nil)
    question = Questions.truth(instructions, if_true: if_true, if_false: if_false)
    helper_answer("check", TruthAnswer, state, question, images, videos, model, boosters, fallback)
  end

  # Asks one `choice` question (id "classify") and returns its ChoiceAnswer.
  # An answer that is missing or malformed raises ServerError.
  def classify(state: UNSET, instructions: nil, options: nil, images: nil, videos: nil, model: nil, boosters: nil,
               fallback: nil)
    helper_answer("classify", ChoiceAnswer, state, Questions.choice(instructions, options), images, videos, model,
                  boosters, fallback)
  end

  # Asks one `score` question (id "score") and returns its ScoreAnswer.
  # An answer that is missing or malformed raises ServerError.
  def score(state: UNSET, instructions: nil, levels: nil, images: nil, videos: nil, model: nil, boosters: nil,
            fallback: nil)
    helper_answer("score", ScoreAnswer, state, Questions.score(instructions, levels), images, videos, model, boosters,
                  fallback)
  end

  # Asks one `number` question (id "number") and returns its NumberAnswer.
  # `min`, `max` and `step` left out take the server's defaults (0, 255, 1).
  # An answer that is missing or malformed raises ServerError.
  def number(state: UNSET, instructions: nil, min: nil, max: nil, step: nil, images: nil, videos: nil, model: nil,
             boosters: nil, fallback: nil)
    question = Questions.number(instructions, min: min, max: max, step: step)
    helper_answer("number", NumberAnswer, state, question, images, videos, model, boosters, fallback)
  end

  # Judges an action before it runs. Sends three questions: "risk" (score),
  # "touches_production" (truth) and "verdict" (choice of allow, confirm or block).
  def gate(action:, context: nil, images: nil, videos: nil, model: nil, boosters: nil, fallback: nil)
    state = { "action" => action }
    state["context"] = context unless context.nil?
    decide(state: state, questions: GATE_QUESTIONS, images: images, videos: videos, model: model, boosters: boosters,
           fallback: fallback)
  end

  # Lists the models with their published limits, as ModelInfo entries. The
  # client keeps the list: a limit only `/v1/models` states (a session's
  # `max_window`, a batch's `requests_per_batch`, a model without number
  # questions) is then checked before sending.
  def models
    body, = request("GET", "/v1/models", nil)
    list = body.is_a?(Hash) && body["models"].is_a?(Array) ? body["models"].grep(Hash) : []
    @held = list.to_h { |m| [m["name"], m] }.freeze
    list.map { |m| ModelInfo.new(m) }
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
  # socket. Only the arguments given are sent, and `model` always is. A
  # session takes no boosters.
  #
  # A 429 `session_limit_exceeded` (the key holds its most open sessions) is
  # never retried and raises SessionLimitError, a RateLimitError.
  def open_session(questions:, state: nil, instructions: nil, model: nil, window: nil, ttl_seconds: nil)
    body = open_body(questions: questions, state: state, instructions: instructions, model: model,
                     window: window, ttl_seconds: ttl_seconds)
    Checks.session_open!(body, limits: limits_for(body["model"]))
    raw, = request("POST", "/v1/sessions", encode(body), encoded: true, policy: :session_open)
    Session.new(self, raw)
  end

  CHECKED_CALLS = %w[decide open_session batches.create batches.add].freeze

  # Runs every local check a call would run before sending, alone: it raises
  # exactly what the call would raise for this request (held /v1/models limits
  # included) and returns nil when the request would be sent. Nothing is sent
  # and nothing is uploaded.
  #
  #   dn.check_request("decide", state: "...", questions: { q: DecisionNode.truth("?") })
  #   dn.check_request(:open_session, { questions: questions, window: 128 }) # raises ValidationError
  #
  # method:: "decide", "open_session", "batches.create" or "batches.add" (a
  #          String or Symbol).
  # request:: the call's keyword arguments, as a Hash or as keywords. For
  #          the batch calls, `requests:`; a `batch_id:` plays no part.
  # Frames are checked with Session#check_frame.
  def check_request(method, request = nil, **args)
    name = method.to_s
    raise ArgumentError, "check_request takes #{CHECKED_CALLS.join(', ')}, got #{method.inspect}" unless CHECKED_CALLS.include?(name)
    raise ArgumentError, "request must be a Hash of the call's arguments" unless request.nil? || request.is_a?(Hash)

    kw = (request || {}).merge(args).to_h { |k, v| [k.to_sym, v] }
    case name
    when "decide"
      unknown = kw.keys - DECIDE_ARGS
      raise ArgumentError, "unknown argument(s) #{unknown.join(', ')} for #{name}" unless unknown.empty?

      prepared_call(**kw)
    when "open_session"
      body = open_body(**kw)
      Checks.session_open!(body, limits: limits_for(body["model"]))
    else
      raise ArgumentError, "requests must be an Array of Hashes" unless kw.fetch(:requests, []).respond_to?(:to_a)

      check_lines(kw.fetch(:requests, []).to_a, allow_empty: name == "batches.create")
    end
    nil
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
    check_lines(list, allow_empty: true)
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
  # images still to be placed (inline or uploaded) when it is sent. Videos
  # are in their wire form already: frames always go inline.
  Prepared = Struct.new(:state, :questions, :images, :videos, :model, :encoded, :boosters, :fallback)
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

  def checked_timeout(value, name = "timeout")
    seconds = Float(value)
    raise ArgumentError, "#{name} must be above 0 seconds, got #{value.inspect}" unless seconds.positive? && seconds.finite?

    seconds
  rescue TypeError
    raise ArgumentError, "#{name} must be a number of seconds, got #{value.inspect}"
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

  DECIDE_ARGS = %i[state questions images videos model boosters fallback].freeze
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

    # A question that is not a Hash is left for the checks, which refuse it as the API does.
    questions.each_pair.to_h do |id, q|
      [id.to_s, !q.is_a?(Hash) || q.keys.all?(String) ? q : q.transform_keys(&:to_s)]
    end
  end

  # The body of POST /v1/sessions: only the fields given, and the model always.
  def open_body(questions:, state: nil, instructions: nil, model: nil, window: nil, ttl_seconds: nil)
    qs = prepared_questions(questions)
    body = { "model" => given(model) || @model }
    body["instructions"] = instructions unless instructions.nil?
    body["state"] = state unless state.nil?
    body["questions"] = qs
    body["window"] = window unless window.nil?
    body["ttl_seconds"] = ttl_seconds unless ttl_seconds.nil?
    body
  end

  # The /v1/models entry of a model, when this client holds it, with the name
  # the request uses: the entry of that name, else the entry that states the
  # name as its `alias` or its pinned `version`. A name the held list does not
  # state holds nothing, and its checks are left to the server.
  def limits_for(model)
    name = given(model) || @model
    entry = @held[name] || @held.each_value.find { |m| m["alias"] == name || m["version"] == name }
    entry ? entry.merge("model" => name) : {}
  end

  # Every fixed rule of a request before it is sent: the body (its images and
  # videos as placeholders, so the nesting counts them) with the counts of
  # its images and videos, then the images, then the videos.
  def check_body(body, images, videos = [])
    probe = body
    probe = probe.merge("images" => images.map { |img| { "id" => image_id(img) } }) unless images.empty?
    probe = probe.merge("videos" => Array.new(videos.size) { { "id" => "", "frames" => [{}] } }) unless videos.empty?
    limits = limits_for(body["model"])
    Checks.request!(probe, limits: limits, counts: Checks.count_entries(images, videos, limits: limits))
    Checks.images!(images, limits: limits)
    Checks.videos!(videos, image_ids: images.map { |img| image_id(img) })
  end

  def image_id(img)
    img.is_a?(Image) ? img.id : img["id"] || img[:id]
  end

  # The image list as given: an Array of Image or wire-form Hashes.
  def prepared_images(images)
    return [] if images.nil?
    raise ArgumentError, "images must be an Array of DecisionNode::Image" unless images.is_a?(Array)

    images.each do |img|
      next if img.is_a?(Image) || img.is_a?(Hash)

      raise ArgumentError, "each image must be a DecisionNode::Image or a wire-form Hash, got #{img.class}"
    end
    images
  end

  # The video list as given: an Array of Video or wire-form Hashes.
  def prepared_videos(videos)
    return [] if videos.nil?
    raise ArgumentError, "videos must be an Array of DecisionNode::Video" unless videos.is_a?(Array)

    videos.each do |video|
      next if video.is_a?(Video) || video.is_a?(Hash)

      raise ArgumentError, "each video must be a DecisionNode::Video or a wire-form Hash, got #{video.class}"
    end
    videos
  end

  # The wire form of a request's videos, or nil when it has none.
  def video_wires(videos)
    videos.empty? ? nil : videos.map { |v| v.is_a?(Video) ? v.to_h : v }
  end

  # The wire form of a request's boosters in the order given, or nil when it
  # names none (nil or an empty Array), so the body then has no `boosters` key.
  # A Booster becomes its wire form; anything else is sent as given, since
  # boosters are the API's to judge.
  def booster_wires(boosters)
    return nil if boosters.nil? || (boosters.is_a?(Array) && boosters.empty?)
    return boosters unless boosters.is_a?(Array)

    boosters.map { |b| b.is_a?(Booster) ? b.wire : b }
  end

  # The fallback argument: nil (left out of the request), true or false.
  def checked_fallback(value)
    return value if value.nil? || value == true || value == false

    raise ArgumentError, "fallback must be true or false, got #{value.inspect}"
  end

  # Checks a request and keeps what is needed to send it. A request without
  # local images is encoded once here.
  def prepared_call(state: UNSET, questions: nil, images: nil, videos: nil, model: nil, boosters: nil, fallback: nil)
    fallback = checked_fallback(fallback)
    qs = prepared_questions(questions)
    imgs = prepared_images(images)
    vids = prepared_videos(videos)
    state = state.equal?(UNSET) || state.nil? ? "" : state
    model = given(model) || @model
    boosted = booster_wires(boosters)
    check_body(body_for(model, state, qs, nil, nil, boosted, fallback), imgs, vids)
    wired = video_wires(vids)
    if imgs.any? { |img| img.is_a?(Image) && img.local? }
      # The body as it will be sent, an image to upload named by a placeholder
      # id of the real length, so nothing is uploaded to measure it. A value
      # that cannot be serialised fails here too.
      projected, = image_wires(imgs, project: true)
      Checks.body_size!(encode(body_for(model, state, qs, projected, wired, boosted, fallback)))
      Prepared.new(state, qs, imgs, wired, model, nil, boosted, fallback)
    else
      wires = imgs.empty? ? nil : imgs.map { |img| img.is_a?(Image) ? img.to_h : img }
      data = encode(body_for(model, state, qs, wires, wired, boosted, fallback))
      Checks.body_size!(data)
      Prepared.new(state, qs, imgs, wired, model, data, boosted, fallback)
    end
  end

  def body_for(model, state, questions, images, videos = nil, boosters = nil, fallback = nil)
    body = { "model" => model, "state" => state, "questions" => questions }
    body["images"] = images unless images.nil?
    body["videos"] = videos unless videos.nil?
    body["boosters"] = boosters unless boosters.nil?
    body["fallback"] = fallback unless fallback.nil?
    body
  end

  def decision_call(path, state, questions, images, videos, model, boosters, fallback)
    call = prepared_call(state: state, questions: questions, images: images, videos: videos, model: model,
                         boosters: boosters, fallback: fallback)
    send_prepared(path, call)
  end

  # Sends a prepared request; returns the Decision and the HTTP status. A
  # request that named uploads the SDK placed, answered with a stale-upload
  # 400, is sent once more with the images uploaded again (not a retry).
  def send_prepared(path, call)
    ocr = ocr_options(call.boosters)
    if call.encoded
      body, headers, status = request("POST", path, call.encoded, encoded: true, **ocr)
      return [Decision.new(body, headers), status]
    end

    2.times do |attempt|
      wires, placed = image_wires(call.images)
      data = encode(body_for(call.model, call.state, call.questions, wires.empty? ? nil : wires, call.videos, call.boosters,
                             call.fallback))
      begin
        body, headers, status = request("POST", path, data, encoded: true, **ocr)
        return [Decision.new(body, headers), status]
      rescue BadRequestError => e
        raise unless attempt.zero? && !placed.empty? && STALE_UPLOAD.include?(e.error_type)

        @uploads.drop(placed)
      end
    end
  end

  # A decision whose boosters name ocr waits 30 s per attempt unless the
  # caller set a timeout, and is never retried after a timeout: the server
  # finishes that attempt and may bill it. Other decisions: no options.
  def ocr_options(boosters)
    list = boosters.is_a?(Array) ? boosters : [boosters]
    names_ocr = list.any? do |b|
      b = b.wire if b.is_a?(Booster)
      b.is_a?(Hash) ? (b["name"] || b[:name]).to_s == "ocr" : (b.is_a?(String) || b.is_a?(Symbol)) && b.to_s == "ocr"
    end
    return {} unless names_ocr

    { policy: :ocr, timeout: @timeout_given ? nil : OCR_TIMEOUT }
  end

  # The typed answer a helper promises, or a ServerError when it is missing
  # or malformed.
  def helper_answer(id, klass, state, question, images, videos, model, boosters, fallback)
    decision, status = decision_call("/v1/decide", state, { id => question }, images, videos, model, boosters, fallback)
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

    wires, = image_wires([image])
    wires.first.reject { |k, _| k == "id" }
  end

  def session_stream(url)
    raise AuthenticationError, "no API key: pass api_key: or set DECISIONNODE_API_KEY" if @api_key.nil?
    raise ArgumentError, "the session has no stream_url" if url.nil?

    headers = { "Authorization" => "Bearer #{@api_key}", "User-Agent" => "decisionnode-ruby/#{VERSION}" }
    options = @http.respond_to?(:session_options) ? @http.session_options.to_h : {}
    proxy = options.fetch(:proxy, :env)
    proxy = URI.parse(proxy) if proxy.is_a?(String)
    SessionStream.new(url, headers.merge(@headers), @timeout, proxy: proxy, tls: options.fetch(:tls, nil) || {})
  end

  # ---- batches

  def line_parts(req, index)
    raise ArgumentError, "batch request #{index + 1} must be a Hash, got #{req.class}" unless req.is_a?(Hash)

    args = req.to_h { |k, v| [k.to_s, v] }
    checked_fallback(args["fallback"])
    [args, prepared_questions(args["questions"]), prepared_images(args["images"]), prepared_videos(args["videos"])]
  rescue ArgumentError => e
    raise e if e.message.start_with?("batch request")

    raise ArgumentError, "batch request #{index + 1}: #{e.message}"
  end

  # The requests of one create or add call, every line checked before any is
  # sent: the custom_id rules, then each line as a decide request, then each
  # line as it would be sent against the body limit.
  def check_lines(requests, allow_empty:)
    Checks.lines!(requests, allow_empty: allow_empty, limits: limits_for(nil))
    requests.each_with_index do |req, i|
      args, questions, images, videos = line_parts(req, i)
      check_body(body_for(given(args["model"]) || @model, args["state"].nil? ? "" : args["state"], questions, nil, nil,
                          booster_wires(args["boosters"]), args["fallback"]), images, videos)
    end
    requests.each_with_index { |req, i| Checks.body_size!(encode(line_for(req, i, project: true))) }
    nil
  end

  # One JSON Lines line: custom_id, model (always), state ("" when absent),
  # questions, images, videos, boosters, fallback (only when given), then any
  # other field as given.
  def batch_line(req, index)
    "#{encode(line_for(req, index))}\n"
  end

  # A batch line as a Hash. With project: true nothing is uploaded: an image
  # to upload is named by a placeholder id of the real length.
  def line_for(req, index, project: false)
    args, questions, images, videos = line_parts(req, index)
    line = { "custom_id" => args["custom_id"], "model" => given(args["model"]) || @model,
             "state" => args["state"].nil? ? "" : args["state"], "questions" => questions }
    line["images"] = image_wires(images, project: project).first unless images.empty?
    line["videos"] = video_wires(videos) unless videos.empty?
    boosted = booster_wires(args["boosters"])
    line["boosters"] = boosted unless boosted.nil?
    line["fallback"] = args["fallback"] unless args["fallback"].nil?
    args.each { |k, v| line[k] = v unless line.key?(k) || %w[images videos boosters fallback].include?(k) }
    line
  end

  # ---- transport

  def encode(body)
    JSON.generate(body, max_nesting: false) # the nesting limit is checked with the request
  rescue JSON::GeneratorError, Encoding::UndefinedConversionError, SystemStackError => e
    raise ArgumentError, "the request cannot be serialised as JSON: #{e.message}"
  end

  # Sends one API request with the retry policy and returns the parsed body
  # (or the text with raw: true), the response headers and the status.
  #
  # policy:: :default retries 408, 429, 5xx, timeouts and connection errors;
  #          :mutation (batch create, add, finalize) only 429 and 529;
  #          :session_open never a 429 `session_limit_exceeded`;
  #          :ocr (a decision whose boosters name ocr) never a timeout, since
  #          the server finishes that attempt and may bill it.
  # timeout:: seconds for each attempt in place of the client's timeout.
  #
  # With a block, a 2xx body is handed to the block line by line as it
  # arrives (when the transport can stream), and the text returned is empty.
  # A stream that fails after its first line is not retried.
  def request(method, path, body, encoded: false, policy: :default, content_type: nil, raw: false, timeout: nil, &on_line)
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
      lines = on_line && @http.respond_to?(:stream) ? LineSplitter.new(on_line) : nil
      begin
        response = if lines
                     stream_once(method, url, headers, lines)
                   else
                     attempt_once(method, url, headers, data, timeout: timeout || @timeout)
                   end
      rescue TimeoutError, ConnectionError => e
        log(method, path, e.class.name.split("::").last, nil, started, attempt)
        raise if attempt >= @max_retries || policy == :mutation || lines&.started?
        raise if policy == :ocr && e.is_a?(TimeoutError)

        @sleeper.call(backoff(attempt))
        attempt += 1
        next
      end
      log(method, path, response.status, response.headers["x-request-id"], started, attempt)

      # Only 2xx is a success. Redirects are never followed, so the key is
      # never sent to another URL or over plain HTTP: a 3xx is an error.
      if (200..299).cover?(response.status)
        if lines
          lines.finish
          return ["", response.headers, response.status]
        end
        response.body.to_s.each_line(&on_line) if on_line
        return [on_line ? "" : response.body.to_s, response.headers, response.status] if raw || on_line

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

  # One streamed attempt: the transport hands a 2xx body over in chunks as it
  # arrives, each read bounded by the timeout, so a results file of any size
  # is read without holding it whole.
  def stream_once(method, url, headers, lines)
    response = @http.stream(method, url, headers, @timeout) { |chunk| lines << chunk }
    unless response.is_a?(HTTPResponse)
      raise ConnectionError, "the transport returned #{response.class}, not a DecisionNode::HTTPResponse"
    end

    response
  end

  # Cuts a stream of chunks into lines and hands each complete one on.
  class LineSplitter
    def initialize(on_line)
      @on_line = on_line
      @buffer = +""
      @started = false
    end

    def <<(chunk)
      @buffer << chunk.b
      while (cut = @buffer.index("\n"))
        line = @buffer.slice!(0, cut + 1)
        @started = true
        @on_line.call(line.force_encoding(Encoding::UTF_8))
      end
    end

    def started?
      @started
    end

    def finish
      return if @buffer.empty?

      @started = true
      @on_line.call(@buffer.force_encoding(Encoding::UTF_8))
      @buffer = +""
    end
  end
  private_constant :LineSplitter

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
  def attempt_once(method, url, headers, data, timeout: @timeout)
    response = begin
      Timeout.timeout(timeout, AttemptDeadline) { @http.call(method, url, headers, data, timeout) }
    rescue AttemptDeadline
      raise TimeoutError, "no complete response within #{timeout} s"
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
    JSON.parse(response.body, max_nesting: false)
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

  # The text of an error status whose body is not JSON, the same in every
  # DecisionNode SDK and never the HTTP library's own wording.
  STATUS_TEXT = {
    400 => "Bad Request", 401 => "Unauthorized", 402 => "Payment Required", 403 => "Forbidden",
    404 => "Not Found", 405 => "Method Not Allowed", 408 => "Request Timeout", 409 => "Conflict",
    410 => "Gone", 413 => "Content Too Large", 422 => "Unprocessable Content", 429 => "Too Many Requests",
    500 => "Internal Server Error", 502 => "Bad Gateway", 503 => "Service Unavailable",
    504 => "Gateway Timeout", 529 => "Overloaded"
  }.freeze
  private_constant :STATUS_TEXT

  def error_for(response)
    body = begin
      JSON.parse(response.body.to_s, max_nesting: false)
    rescue JSON::ParserError
      # Not the API's envelope (an edge's or a proxy's page, or no body): the
      # class follows the status alone and the body is never read.
      return error_from(response.status, response.headers, nil,
                        message: edge_message(response.status, response.headers))
    end
    error_from(response.status, response.headers, body)
  end

  # "HTTP <status> <text>", then the request id when the response has one.
  def edge_message(status, headers)
    text = "HTTP #{status}"
    text += " #{STATUS_TEXT[status]}" if STATUS_TEXT.key?(status)
    request_id = headers["x-request-id"]
    request_id.nil? ? text : "#{text} (request id #{request_id})"
  end

  # The error the API's answer gives: the class by status (and error_type),
  # with the fields read from the body and headers. `message` is given for a
  # body that is not JSON, which then plays no part.
  def error_from(status, headers, body, message: nil)
    detail = body.is_a?(Hash) ? body["detail"] : nil
    error_type = entries = category = nil
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
    when 413 then RequestTooLargeError.new(message, **kw)
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
