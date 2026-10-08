# frozen_string_literal: true

require "openssl"
require "socket"
require "uri"
require "websocket/driver"

class DecisionNode
  # The socket of a session: RFC 6455 through websocket-driver over a TCP or
  # TLS socket from the standard library, with one reader thread. Pings are
  # answered at once; a socket that receives nothing, pings included, for
  # IDLE_LIMIT seconds is treated as lost (1006). Used by Session; not used directly.
  #
  # The socket follows the client's transport where a WebSocket can: a `wss`
  # URL goes through the transport's proxy (else the proxy the environment
  # names for Net::HTTP, `no_proxy` honoured) with an HTTP CONNECT tunnel, and
  # TLS takes the transport's `net_http:` trust and client certificate
  # settings (ca_file, ca_path, cert_store, cert, key, ...), with peer and
  # hostname checks always on.
  class SessionStream
    # The server pings every 20 s and drops a socket after 45 s of silence.
    IDLE_LIMIT = 65
    MAX_MESSAGE = 16 * 1024 * 1024

    attr_reader :url, :events

    # The `net_http:` settings that apply to the session's TLS context.
    TLS_SETTINGS = %w[ca_file ca_path cert_store cert key extra_chain_cert ssl_version min_version max_version
                      ciphers verify_depth].freeze

    # proxy:: a proxy URI, :env to take the one the environment names, or nil for none.
    # tls::   settings by name (TLS_SETTINGS); others are ignored.
    def initialize(url, headers, timeout, proxy: :env, tls: {})
      @url = url
      @proxy = proxy
      @tls = tls
      @events = Queue.new
      @write_lock = Mutex.new
      @driver_lock = Mutex.new
      @finish_lock = Mutex.new
      @opened = Queue.new
      @done = false
      @io = open_socket(URI.parse(url), timeout)
      @driver = Driver.new(self, max_length: MAX_MESSAGE)
      headers.each { |name, value| @driver.set_header(name, value) }
      @driver.on(:open) { @opened << [:open] }
      @driver.on(:message) { |e| @events << [:message, e.data] }
      @driver.on(:close) { |e| finish(@driver.received_close_code || e.code || 1005, e.reason.to_s) }
      @driver_lock.synchronize { @driver.start }
      @reader = Thread.new { read_loop }
      @reader.report_on_exception = false
      await_open(timeout)
    end

    # Sends one text message.
    def text(data)
      @driver_lock.synchronize { @driver.text(data) }
    end

    def close(code)
      @driver_lock.synchronize { @driver.close("", code) }
    end

    # Called by the driver.
    def write(data)
      @write_lock.synchronize { @io.write(data) }
    rescue IOError, SystemCallError, OpenSSL::SSL::SSLError
      finish(1006, "")
    end

    def close_socket
      @done = true
      @io.close unless @io.closed?
    rescue IOError, SystemCallError, OpenSSL::SSL::SSLError
      nil
    end

    private

    LOOPBACK = %w[localhost 127.0.0.1 ::1].freeze

    def open_socket(uri, timeout)
      host = uri.host.to_s.delete_prefix("[").delete_suffix("]")
      case uri.scheme&.downcase
      when "wss"
        port = uri.port || 443
        proxy = proxy_for(host, port)
        tcp = proxy ? self.class.tunnel(proxy, host, port, timeout) : Socket.tcp(host, port, connect_timeout: timeout)
        tls(tcp, host, timeout)
      when "ws"
        raise ArgumentError, "the stream URL must use wss, got #{uri}" unless LOOPBACK.include?(host.downcase)

        tcp = Socket.tcp(host, uri.port || 80, connect_timeout: timeout)
        tcp.setsockopt(Socket::IPPROTO_TCP, Socket::TCP_NODELAY, 1)
        tcp
      else
        raise ArgumentError, "the stream URL must use wss, got #{uri}"
      end
    rescue Errno::ETIMEDOUT, IO::TimeoutError => e
      raise DecisionNode::TimeoutError, "no connection to the session stream within #{timeout} s (#{e.class})"
    rescue SocketError, SystemCallError => e
      raise DecisionNode::ConnectionError, "cannot connect to the session stream: #{e.message} (#{e.class})"
    end

    # The proxy for a wss host: the transport's, else the environment's as
    # Net::HTTP finds it (no_proxy honoured), else none.
    def proxy_for(host, port)
      return @proxy unless @proxy == :env

      URI::HTTP.new("http", nil, host, port, nil, nil, nil, nil, nil).find_proxy
    end

    def tls(tcp, host, timeout)
      tcp.setsockopt(Socket::IPPROTO_TCP, Socket::TCP_NODELAY, 1)
      ssl = OpenSSL::SSL::SSLSocket.new(tcp, self.class.tls_context(@tls))
      ssl.hostname = host
      ssl.sync_close = true
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
      loop do
        case ssl.connect_nonblock(exception: false)
        when :wait_readable then wait(tcp, :r, deadline)
        when :wait_writable then wait(tcp, :w, deadline)
        else break
        end
      end
      ssl.post_connection_check(host)
      ssl
    rescue OpenSSL::SSL::SSLError => e
      tcp.close
      raise DecisionNode::ConnectionError, "TLS to the session stream failed: #{e.message}"
    end

    # A TLS context with the given settings, certificate and hostname checks on.
    def self.tls_context(settings)
      params = settings.to_h { |k, v| [k.to_s.delete_suffix("="), v] }.select { |k, _| TLS_SETTINGS.include?(k) }
      context = OpenSSL::SSL::SSLContext.new
      context.set_params(params.transform_keys(&:to_sym).merge(verify_mode: OpenSSL::SSL::VERIFY_PEER, verify_hostname: true))
      context
    end

    # A TCP socket to host:port through an HTTP proxy's CONNECT tunnel.
    def self.tunnel(proxy, host, port, timeout)
      unless proxy.scheme.to_s.casecmp?("http")
        raise DecisionNode::ConnectionError, "a session socket goes through an http:// proxy only, got #{proxy.scheme}://"
      end

      tcp = Socket.tcp(proxy.host, proxy.port || 80, connect_timeout: timeout)
      target = host.include?(":") ? "[#{host}]:#{port}" : "#{host}:#{port}"
      head = +"CONNECT #{target} HTTP/1.1\r\nHost: #{target}\r\n"
      if proxy.user
        login = [proxy.user, proxy.password.to_s].map { |part| URI.decode_www_form_component(part) }.join(":")
        head << "Proxy-Authorization: Basic #{[login].pack('m0')}\r\n"
      end
      tcp.write("#{head}\r\n")
      answer = read_head(tcp, Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout)
      status = answer[%r{\AHTTP/1\.[01] (\d{3})}, 1].to_i
      return tcp if status == 200

      tcp.close
      raise DecisionNode::ConnectionError, "the proxy refused the tunnel to the session stream with HTTP #{status}"
    rescue IOError, SystemCallError => e
      tcp&.close
      raise DecisionNode::ConnectionError, "the proxy tunnel to the session stream failed: #{e.message} (#{e.class})"
    end

    # The proxy's answer up to the blank line, read a byte at a time so nothing
    # of the tunnel is taken.
    def self.read_head(io, deadline)
      head = +""
      until head.end_with?("\r\n\r\n")
        left = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
        raise DecisionNode::TimeoutError, "the proxy did not answer in time" unless left.positive? && io.wait_readable(left)

        byte = io.read_nonblock(1, exception: false)
        next if byte == :wait_readable
        raise DecisionNode::ConnectionError, "the proxy closed the connection" if byte.nil?

        head << byte
        raise DecisionNode::ConnectionError, "the proxy's answer is too long" if head.bytesize > 16_384
      end
      head
    end

    def wait(io, dir, deadline)
      left = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
      ready = left.positive? && (dir == :r ? io.wait_readable(left) : io.wait_writable(left))
      raise DecisionNode::TimeoutError, "no TLS handshake with the session stream in time" unless ready
    end

    def await_open(timeout)
      first = @opened.pop(timeout: timeout)
      if first.nil?
        close_socket
        raise DecisionNode::TimeoutError, "the session stream did not open within #{timeout} s"
      end
      return if first.first == :open

      _, code, reason = first
      status = @driver.status
      if status && status != 101
        raise DecisionNodeError.new("the session stream refused the upgrade with HTTP #{status}", status: status)
      end
      raise SessionClosed.new(code, reason)
    end

    def read_loop
      until @done
        if !(@io.respond_to?(:pending) && @io.pending.positive?) && !@io.to_io.wait_readable(IDLE_LIMIT)
          finish(1006, "no traffic for #{IDLE_LIMIT} s")
          break
        end
        data = @io.read_nonblock(65_536, exception: false)
        next if data == :wait_readable || data == :wait_writable

        if data.nil?
          finish(1006, "")
          break
        end
        @driver_lock.synchronize { @driver.parse(data) }
      end
    rescue IOError, SystemCallError, OpenSSL::SSL::SSLError
      finish(1006, "")
    end

    # Records the close once, closes the socket and wakes #connect.
    def finish(code, reason)
      first = @finish_lock.synchronize do
        next false if @finished

        @finished = true
      end
      return unless first

      @events << [:close, code, reason]
      @opened << [:close, code, reason]
      close_socket
    end

    # The driver, keeping the close code the server sent: websocket-driver
    # replaces codes it does not list (1012 to 1014, 1013 among them) with 1002.
    class Driver < ::WebSocket::Driver::Client
      attr_reader :received_close_code

      private

      def emit_frame(buffer)
        if @frame.opcode == OPCODES[:close] && buffer.bytesize >= 2
          payload = ::WebSocket::Mask.mask(buffer.dup, @frame.masking_key)
          @received_close_code = payload.unpack1("S>")
        end
        super
      end
    end
  end
end
