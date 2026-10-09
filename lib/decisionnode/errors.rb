# frozen_string_literal: true

class DecisionNode
  # The base of every error this gem raises, and the class of an error for a
  # status no subclass covers (a 3xx, 405, 409, or 408 once its retries are spent).
  #
  # The error's own `message` is the server's message (`detail.message`, or
  # `detail` when it is a string), or the client's description when there was
  # no response. It is an empty string when the server sent none. `reason` is
  # the server's explanation in words, from the `x-decisionnode-error` header.
  # `boosters` is the `x-decisionnode-boosters` header of a request that
  # named boosters, as booster name to BoosterStatus in the request's order
  # (an empty Hash when there is none), so a caller can see which required
  # booster failed. The report Ruby prints for an uncaught error adds the class, status and
  # reason.
  class DecisionNodeError < StandardError
    include DecisionResult

    attr_reader :status, :error_type, :request_id, :reason, :body, :headers, :boosters

    def initialize(message = nil, status: nil, error_type: nil, request_id: nil, reason: nil, body: nil, headers: nil)
      @status = status
      @error_type = error_type
      @request_id = request_id
      @reason = reason
      @body = body
      @headers = headers || {}
      @boosters = BoosterStatus.parse(@headers["x-decisionnode-boosters"])
      super(message.nil? ? "" : message.to_s)
    end

    def detailed_message(highlight: false, **)
      parts = []
      parts << message unless message.empty?
      parts << "HTTP #{status}" if status
      parts << "error_type: #{error_type}" if error_type
      parts << "reason: #{reason}" if reason
      parts << "request_id: #{request_id}" if request_id
      "#{parts.empty? ? 'DecisionNode error' : parts.join('; ')} (#{self.class.name})"
    end
  end

  # 400: the request is malformed or breaks a limit of the model. Also raised
  # before any request when the SDK finds a fault the API would answer with a
  # 400 (an image, an option or level count): such an error has no status and
  # no request id.
  class BadRequestError < DecisionNodeError; end

  # 400 with `error_type` `max_tokens_exceeded`: the input is too long for the model.
  class ContextLimitError < BadRequestError; end

  # 401: the API key is missing or not valid.
  class AuthenticationError < DecisionNodeError; end

  # 402: the account has no credit left.
  class InsufficientCreditError < DecisionNodeError; end

  # 403 that is not a refusal: the workspace may not do this, for example use
  # a booster turned off for it (`booster_not_enabled`), or it is suspended.
  # `error_type` tells them apart.
  class PermissionDeniedError < DecisionNodeError; end

  # 403 with `error_type` `refusal_error`: the request was refused under the usage policy.
  class RefusalError < DecisionNodeError
    # "harm" or "self_harm".
    attr_reader :category
    # The parsed `x-decisionnode-safety` header, a Safety or nil.
    attr_reader :safety

    def initialize(message = nil, category: nil, safety: nil, **kw)
      @category = category
      @safety = safety
      super(message, **kw)
    end
  end

  # 404: the path or resource does not exist.
  class NotFoundError < DecisionNodeError; end

  # 422: the request body does not match the schema. Also raised before any
  # request for a number grid the API would refuse, or a score with no levels.
  class ValidationError < DecisionNodeError
    # The server's list of validation entries.
    attr_reader :entries

    def initialize(message = nil, entries: nil, **kw)
      @entries = entries
      super(message, **kw)
    end
  end

  # 429: too many requests.
  class RateLimitError < DecisionNodeError
    # Seconds to wait before trying again, or nil.
    attr_reader :retry_after

    def initialize(message = nil, retry_after: nil, **kw)
      @retry_after = retry_after
      super(message, **kw)
    end
  end

  # 429 with `error_type` `session_limit_exceeded`: the key already holds as
  # many open sessions as it may. Never retried.
  class SessionLimitError < RateLimitError; end

  # 529: the service is overloaded, or (`error_type` `booster_unavailable`) a
  # booster the request required failed or did not answer in time. Retried
  # like every 529.
  class OverloadedError < DecisionNodeError
    # Seconds to wait before trying again, or nil.
    attr_reader :retry_after

    def initialize(message = nil, retry_after: nil, **kw)
      @retry_after = retry_after
      super(message, **kw)
    end
  end

  # Any other 5xx, or a successful status with a body that is not JSON.
  class ServerError < DecisionNodeError; end

  # No response: the connection failed or was dropped.
  class ConnectionError < DecisionNodeError; end

  # No response within the timeout.
  class TimeoutError < DecisionNodeError; end
end
