# frozen_string_literal: true

class DecisionNode
  # The loop behind DecisionNode#supervise: one feed, sessions reopened as the
  # close codes say. Not used directly.
  class Supervisor
    # Codes after which no backoff is needed before the next session: the
    # session went idle (4408) or reached its end of life (4410).
    AT_ONCE = [4408, 4410].freeze

    def initialize(client, body, handler, max_sessions, drain_timeout)
      @client = client
      @body = body
      @handler = handler
      @max_sessions = max_sessions
      @drain_timeout = drain_timeout
      @session = nil  # the session being fed, nil when none is connected
      @kept = nil     # a session closed with 1013, to connect to again
      @last = nil     # the last SessionClosed seen
      @connects = 0
      @failures = 0
      @answered = 0
      @pending = 0
    end

    def run(feed)
      feed.each do |reading|
        drain(0)
        until @session
          return @last if stopped? || @connects >= @max_sessions

          pause_before_connect
          connect
        end
        @session.send_frame(**reading.to_h { |k, v| [k.to_sym, v] })
        @pending += 1
      end
      drain(@drain_timeout)
      if @session
        @session.end_session
        @session.close
      end
      @last
    end

    private

    def stopped?
      @last && !@last.reopen && @last.code != SessionClosed::TRY_AGAIN
    end

    # A capped backoff with jitter, 1 s doubling to 30 s, reset after a
    # session that answered frames; none after 4408 and 4410.
    def pause_before_connect
      return if @last.nil? || AT_ONCE.include?(@last.code)

      @failures = 0 if @answered.positive?
      base = [DecisionNode::RECONNECT_CAP, DecisionNode::RECONNECT_START * (2**@failures)].min
      @client.__send__(:pause, base * (0.5 + (rand * 0.5)))
      @failures += 1
    end

    def connect
      session = if @last&.code == SessionClosed::TRY_AGAIN && @kept
                  @kept
                else
                  @client.open_session(**@body)
                end
      @connects += 1
      @answered = 0
      @pending = 0
      @last = nil
      @kept = nil
      session.connect
      @session = session
    rescue SessionClosed => e
      closed(e, session)
    end

    def closed(event, session)
      @last = event
      @kept = event.code == SessionClosed::TRY_AGAIN ? session : nil
      @session = nil
    end

    # Hands every event that arrived to the handler. With a wait, waits up to
    # that many seconds for the outstanding replies.
    def drain(wait)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + wait
      while @session
        timeout = wait.zero? ? 0 : [deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC), 0.01].max
        event = @session.next_event(timeout: timeout)
        return if event.nil?

        if event.is_a?(SessionClosed)
          closed(event, @session)
          return
        end
        dropped = event.is_a?(Reply) ? (event.dropped || []).size : 0
        @pending = [@pending - 1 - dropped, 0].max
        @answered += 1 if event.is_a?(Reply)
        @handler.call(event)
        return if wait.positive? && @pending.zero?
      end
    end
  end
end
