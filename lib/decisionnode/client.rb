# frozen_string_literal: true

require "json"
require "time"
require "timeout"
require "uri"

class DecisionNode
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

  attr_reader :base_url, :model, :timeout, :max_retries

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
  # headers::     extra headers sent with every request.
  # http_client:: a NetHTTPTransport built with your own options, or another
  #               transport with the interface of NetHTTPTransport#call.
  # logger::      a Logger; when given, each attempt is logged at debug level
  #               (method, path, status, request id and timing, never the body).
  #
  # A client is safe to share between threads and reuses its connections.
  def initialize(api_key: nil, base_url: nil, model: nil, timeout: nil, max_retries: nil,
                 headers: nil, http_client: nil, logger: nil)
    @api_key = given(api_key) || env("DECISIONNODE_API_KEY")
    @base_url = checked_base_url((given(base_url) || env("DECISIONNODE_BASE_URL") || DEFAULT_BASE_URL).chomp("/"))
    @model = given(model) || env("DECISIONNODE_MODEL") || DEFAULT_MODEL
    @timeout = timeout.nil? ? DEFAULT_TIMEOUT : checked_timeout(timeout)
    @max_retries = max_retries.nil? ? DEFAULT_MAX_RETRIES : checked_max_retries(max_retries)
    @headers = (headers || {}).to_h { |k, v| [k.to_s, v.to_s] }.freeze
    @http = checked_http_client(http_client) || NetHTTPTransport.new
    @logger = logger
    @sleeper = ->(seconds) { sleep(seconds) }
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
  def decide(state: UNSET, questions: nil, images: nil, model: nil)
    send_decide(encode(decide_body(state, questions, images, model))).first
  end

  # Runs several #decide calls, at most `concurrency` at a time. Each request is
  # a Hash of #decide's arguments. Returns one entry per request, in input
  # order: a Decision, or the error that request ended with. One failure does
  # not stop the others. Each entry is a DecisionResult.
  #
  # Every request is checked before any is sent: a concurrency below 1, or any
  # request #decide would refuse, raises ArgumentError and nothing is sent.
  def decide_many(requests, concurrency: DEFAULT_CONCURRENCY)
    limit = begin
      Integer(concurrency)
    rescue TypeError, FloatDomainError
      raise ArgumentError, "concurrency must be a whole number of at least 1, got #{concurrency.inspect}"
    end
    raise ArgumentError, "concurrency must be at least 1, got #{limit}" if limit < 1
    raise ArgumentError, "requests must be an Array of Hashes of decide's arguments" unless requests.respond_to?(:to_a)

    bodies = requests.to_a.each_with_index.map do |item, i|
      encode(prepared_body(**decide_args(item)))
    rescue ArgumentError => e
      raise ArgumentError, "decide_many: request #{i}: #{e.message}"
    end
    results = Array.new(bodies.size)
    return results if bodies.empty?

    queue = Queue.new
    bodies.each_index { |i| queue << i }
    workers = Array.new([limit, bodies.size].min) do
      Thread.new do
        loop do
          i = begin
            queue.pop(true)
          rescue ThreadError
            break
          end
          results[i] = result_for { send_decide(bodies[i]).first }
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
    helper_answer("check", TruthAnswer, decide_body(state, { "check" => question }, images, model))
  end

  # Asks one `choice` question (id "classify") and returns its ChoiceAnswer.
  # An answer that is missing or malformed raises ServerError.
  def classify(state: UNSET, instructions: nil, options: nil, images: nil, model: nil)
    question = Questions.choice(instructions, options)
    helper_answer("classify", ChoiceAnswer, decide_body(state, { "classify" => question }, images, model))
  end

  # Asks one `score` question (id "score") and returns its ScoreAnswer.
  # An answer that is missing or malformed raises ServerError.
  def score(state: UNSET, instructions: nil, levels: nil, images: nil, model: nil)
    question = Questions.score(instructions, levels)
    helper_answer("score", ScoreAnswer, decide_body(state, { "score" => question }, images, model))
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
  def decide_raw(body)
    parsed, = request("POST", "/v1/decide", body)
    parsed
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

  def checked_max_retries(value)
    count = value.is_a?(Float) && value != value.floor ? nil : Integer(value)
    raise ArgumentError, "max_retries must be a whole number of 0 or more, got #{value.inspect}" if count.nil? || count.negative?

    count
  rescue TypeError, FloatDomainError
    raise ArgumentError, "max_retries must be a whole number of 0 or more, got #{value.inspect}"
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

  def prepared_body(state: UNSET, questions: nil, images: nil, model: nil)
    decide_body(state, questions, images, model)
  end

  def decide_body(state, questions, images, model)
    if questions.nil? || !questions.respond_to?(:each_pair) || questions.empty?
      raise ArgumentError, "questions must hold at least one question"
    end

    body = {
      "model" => given(model) || @model,
      "state" => state.equal?(UNSET) || state.nil? ? "" : state,
      "questions" => questions.each_pair.to_h do |id, q|
        raise ArgumentError, "question #{id.to_s.inspect} must be a Hash, got #{q.class}" unless q.is_a?(Hash)

        [id.to_s, q]
      end
    }
    unless images.nil?
      raise ArgumentError, "images must be an Array of DecisionNode::Image" unless images.is_a?(Array)

      unless images.empty?
        body["images"] = images.map do |img|
          next img.to_h if img.is_a?(Image)
          next img if img.is_a?(Hash)

          raise ArgumentError, "each image must be a DecisionNode::Image or a wire-form Hash, got #{img.class}"
        end
      end
    end
    body
  end

  # Sends an encoded decide body; returns the Decision and the HTTP status.
  def send_decide(data)
    body, headers, status = request("POST", "/v1/decide", data, encoded: true)
    [Decision.new(body, headers), status]
  end

  # The typed answer a helper promises, or a ServerError when it is missing
  # or malformed.
  def helper_answer(id, klass, body)
    decision, status = send_decide(encode(body))
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

  def encode(body)
    JSON.generate(body)
  rescue JSON::GeneratorError, Encoding::UndefinedConversionError, SystemStackError => e
    raise ArgumentError, "the request cannot be serialised as JSON: #{e.message}"
  end

  def request(method, path, body, encoded: false)
    if @api_key.nil? || @api_key.to_s.empty?
      raise AuthenticationError, "no API key: pass api_key: or set DECISIONNODE_API_KEY"
    end

    data = body.nil? || encoded ? body : encode(body)
    headers = {
      "Authorization" => "Bearer #{@api_key}",
      "User-Agent" => "decisionnode-ruby/#{VERSION}",
      "Accept" => "application/json"
    }
    headers["Content-Type"] = "application/json" unless data.nil?
    headers.merge!(@headers)
    url = @base_url + path

    attempt = 0
    loop do
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      begin
        response = attempt_once(method, url, headers, data)
      rescue TimeoutError, ConnectionError => e
        log(method, path, e.class.name.split("::").last, nil, started, attempt)
        raise if attempt >= @max_retries

        @sleeper.call(backoff(attempt))
        attempt += 1
        next
      end
      log(method, path, response.status, response.headers["x-request-id"], started, attempt)

      # Only 2xx is a success. Redirects are never followed, so the key is
      # never sent to another URL or over plain HTTP: a 3xx is an error.
      return [parse_success(response), response.headers, response.status] if (200..299).cover?(response.status)

      if RETRY_STATUSES.include?(response.status) && attempt < @max_retries
        wait = retry_wait(response.headers)
        @sleeper.call(wait.nil? ? backoff(attempt) : wait)
        attempt += 1
        next
      end
      raise error_for(response)
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
  rescue JSON::ParserError => e
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
    ms = number(headers["retry-after-ms"])
    seconds = ms.nil? ? nil : ms / 1000.0
    seconds ||= number(headers["retry-after"]) || http_date_wait(headers["retry-after"])
    return nil if seconds.nil? || seconds.nan?

    seconds.clamp(0.0, RETRY_AFTER_CAP)
  end

  def http_date_wait(value)
    return nil if value.nil?

    Time.httpdate(value.strip) - Time.now
  rescue ArgumentError
    nil
  end

  def number(value)
    value.nil? ? nil : Float(value.strip)
  rescue ArgumentError
    nil
  end

  def error_for(response)
    status = response.status
    headers = response.headers
    body = begin
      JSON.parse(response.body)
    rescue JSON::ParserError
      nil
    end
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
    when 429 then RateLimitError.new(message, retry_after: retry_wait(headers), **kw)
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
