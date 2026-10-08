# frozen_string_literal: true

require "json"
require "uri"

class DecisionNode
  # The reply to one session frame.
  class Reply
    # The `seq` of the frame answered.
    attr_reader :seq
    # Question id to typed Answer, as in a Decision.
    attr_reader :answers
    # The `seq` of each frame this frame superseded, in arrival order, or nil.
    attr_reader :dropped
    # Token counts of this frame, a Usage.
    attr_reader :usage
    # The worker's time for this frame, in milliseconds.
    attr_reader :latency_ms
    # The safety check on this frame, as the server sent it (a Hash), or nil.
    attr_reader :safety
    # The message as received.
    attr_reader :raw

    def initialize(raw)
      @raw = raw
      @seq = raw["seq"]
      @answers = Answer.map(raw["answers"])
      @dropped = raw["dropped"]
      @usage = Usage.new(raw.dig("usage", "input_tokens"), raw.dig("usage", "output_tokens")) if raw["usage"].is_a?(Hash)
      @latency_ms = raw["latency_ms"]
      @safety = raw["safety"]
    end

    # The answer to the question with this id.
    def [](id)
      answers.fetch(id.to_s) { raise KeyError, "no answer with the id #{id.to_s.inspect}" }
    end
  end

  # A frame the session could not answer. A value, never raised: the session
  # stays open and the next frame can be sent.
  class FrameError
    # The frame's `seq`, or nil when the message could not be read as a frame.
    attr_reader :seq
    attr_reader :error_type, :message, :category
    # The wait the server asks for before the next frame, for `rate_limit_error`
    # and `overloaded_error`.
    attr_reader :retry_after_ms
    # What a refused frame billed (a Usage), and its safety result (a Hash).
    attr_reader :usage, :safety
    attr_reader :raw

    def initialize(raw)
      @raw = raw
      @seq = raw["seq"]
      @error_type = raw.dig("error", "error_type")
      @message = raw.dig("error", "message")
      @category = raw.dig("error", "category")
      @retry_after_ms = raw["retry_after_ms"]
      @usage = Usage.new(raw.dig("usage", "input_tokens"), raw.dig("usage", "output_tokens")) if raw["usage"].is_a?(Hash)
      @safety = raw["safety"]
    end
  end

  # The end of a session's stream, with the close code. It is the last event
  # of Session#replies, and is raised by Session#connect when the server
  # refuses the socket before it opens.
  class SessionClosed < StandardError
    # Codes after which a new session with the same body is the remedy:
    # 1001, 1006 (the connection was lost without a close frame), 1011, 4404,
    # 4408, 4409 and 4410.
    REOPEN_CODES = [1001, 1006, 1011, 4404, 4408, 4409, 4410].freeze
    # The server is at its socket limit; the session is kept, connect again.
    TRY_AGAIN = 1013

    attr_reader :code, :reason

    def initialize(code, reason = "")
      @code = code
      @reason = reason.to_s
      super("session closed with #{code}#{@reason.empty? ? '' : " (#{@reason})"}")
    end

    # True for the codes after which a new session with the same body is the
    # remedy; false otherwise, 1013 included (the session is kept).
    def reopen
      REOPEN_CODES.include?(code)
    end
    alias reopen? reopen
  end

  # An open session: one state, a fixed set of questions, and a stream of
  # frames answered as they arrive. Made by DecisionNode#open_session.
  #
  #   s = dn.open_session(state: { mission: "Survey" }, questions: { abort: DecisionNode.truth("Abort?") })
  #   s.connect
  #   s.send(frame: { battery: 0.31 })
  #   s.replies.each { |event| ... } # Reply, FrameError, then SessionClosed
  #   s.end
  #
  # Every field of the open response is available by name (`session_id`,
  # `model`, `stream_url`, `window`, `ttl_seconds`, `expires_at`, `limits`,
  # `questions`, `prefix_tokens`, `usage`, `safety`) or as `session["field"]`.
  # The socket is safe to send on from several threads; read the replies from
  # one.
  class Session
    # The open response as received.
    attr_reader :raw
    # The answers to the session's questions on the state alone, typed.
    attr_reader :answers

    FIELDS = %w[session_id model stream_url window ttl_seconds expires_at limits questions prefix_tokens usage safety].freeze

    FIELDS.each do |name|
      define_method(name) { @raw[name] }
    end

    def initialize(client, raw)
      @client = client
      @raw = raw.is_a?(Hash) ? raw : {}
      @answers = Answer.map(@raw["answers"])
      @seq = 0
      @seq_lock = Mutex.new
      @stream = nil
      @closed = nil
    end

    def id
      session_id
    end

    def [](key)
      @raw[key.to_s]
    end

    def inspect
      "#<#{self.class.name} #{session_id.inspect} model=#{model.inspect}>"
    end

    # Opens the socket: the key in the Authorization header (never in the URL)
    # and the client's custom headers on the handshake. Returns self. A server
    # that closes the socket before it opens raises SessionClosed; a refusal
    # sent right after it opens is the first event of #replies. Connecting
    # again after a close (for example after 1013) opens a new socket to the
    # same session.
    def connect
      @stream&.close_socket
      @closed = nil
      @stream = @client.__send__(:session_stream, stream_url)
      self
    end

    # Sends one frame and returns its `seq`; never waits for a reply.
    #
    # frame::     text or any JSON value (the reading).
    # image::     one Image: sent inline under the client's inline threshold,
    #             else uploaded first and sent by `upload_id`. A URL image is
    #             refused: frames take bytes or an upload.
    # questions:: the ids of the session's questions to ask (default all).
    # reset::     true empties the window before this frame is answered.
    # seq::       the frame's number; by default a counter from 1.
    def send_frame(frame: nil, image: nil, questions: nil, reset: nil, seq: nil)
      raise ArgumentError, "connect the session before sending" if @stream.nil?

      message = { "seq" => seq.nil? ? next_seq : seq }
      message["frame"] = frame unless frame.nil?
      message["image"] = @client.__send__(:frame_image, image) unless image.nil?
      message["questions"] = questions.map(&:to_s) unless questions.nil?
      message["reset"] = reset unless reset.nil?
      @stream.text(@client.__send__(:encode, message))
      message["seq"]
    end

    # Session#send with keyword arguments sends a frame (see #send_frame);
    # with a method name it is Object#send.
    def send(*args, **kwargs, &block)
      return super unless args.empty? && block.nil?

      send_frame(**kwargs)
    end

    # The next event: a Reply, a FrameError, or the SessionClosed that ends
    # the stream (returned again on every later call). nil when nothing
    # arrived within `timeout` seconds (nil waits without limit).
    def next_event(timeout: nil)
      return @closed if @closed
      raise ArgumentError, "connect the session before reading" if @stream.nil?

      event = @stream.events.pop(timeout: timeout)
      return nil if event.nil?

      kind, a, b = event
      if kind == :close
        @closed = SessionClosed.new(a, b)
        return @closed
      end
      parse_message(a)
    end

    # Each event in turn: Reply and FrameError values, then the SessionClosed
    # that ends the stream. Without a block, an Enumerator.
    def replies(timeout: nil)
      return enum_for(:replies, timeout: timeout) unless block_given?

      loop do
        event = next_event(timeout: timeout)
        return nil if event.nil?

        yield event
        return nil if event.is_a?(SessionClosed)
      end
    end

    # Closes the socket with 1000. The session ends on the server.
    def close
      @stream&.close(1000)
      nil
    end

    # Ends the session (`DELETE /v1/sessions/{id}`); the server then closes the
    # socket with 1000. A session that is already gone (404) counts as ended.
    # Returns the response body, or nil after a 404.
    def end_session
      body, = @client.__send__(:request, "DELETE", "/v1/sessions/#{URI.encode_www_form_component(session_id.to_s)}", nil)
      body
    rescue NotFoundError
      nil
    end
    alias end end_session

    # Closes the socket without a close frame. For the client's own use.
    def drop
      @stream&.close_socket
    end

    private

    def next_seq
      @seq_lock.synchronize { @seq += 1 }
    end

    def parse_message(text)
      raw = JSON.parse(text)
      raise JSON::ParserError, "not an object" unless raw.is_a?(Hash)

      raw.key?("error") ? FrameError.new(raw) : Reply.new(raw)
    rescue JSON::ParserError
      FrameError.new({ "seq" => nil, "error" => { "error_type" => "invalid_message",
                                                  "message" => "the server sent a message that is not a JSON object" } })
    end
  end
end
