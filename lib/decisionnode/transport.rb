# frozen_string_literal: true

require "net/http"
require "openssl"
require "uri"

class DecisionNode
  # A response as the client sees it: the status, the headers with lower-case
  # names, and the body text. A transport that can follow redirects sets `url`
  # to the address the response came from; the client refuses a response from
  # any other address than the one it asked for.
  HTTPResponse = Struct.new(:status, :headers, :body, :url)

  # The default transport: Net::HTTP with a pool of kept-alive connections per
  # host, safe to share between threads, so repeated calls skip the TCP and
  # TLS handshakes. It never follows a redirect.
  #
  #   DecisionNode::NetHTTPTransport.new(
  #     proxy: "http://proxy.example.com:3128",
  #     net_http: { ca_file: "/etc/ssl/certs/company-ca.pem" }
  #   )
  #
  # max_idle::  idle connections kept per host (default 16).
  # keep_alive_timeout:: seconds an idle connection is reused for (default 15).
  # proxy::    a proxy URL, else the proxy environment variables Net::HTTP reads.
  # net_http:: Net::HTTP settings applied to every connection, by setter name
  #            (ca_file, ca_path, cert_store, cert, key, ...). Settings that
  #            could turn TLS or its certificate checks off are refused with
  #            ArgumentError: use_ssl (the transport sets it from the URL),
  #            verify_mode other than VERIFY_PEER, verify_hostname false and
  #            verify_callback. For an https URL TLS with peer and hostname
  #            checks is set again after the caller's settings.
  #
  # Any object with the same `call` method can be passed to the client as
  # `http_client:`. It returns an HTTPResponse and raises
  # DecisionNode::TimeoutError or DecisionNode::ConnectionError when no response
  # arrives. Methods are GET, POST, PUT (an image upload to the storage URL the
  # API returned, with exactly the headers given) and DELETE. It must never follow a redirect and must say so by answering false
  # to `follow_redirects?`; the client refuses any other transport. A response
  # whose `url` differs from the requested one is an error.
  class NetHTTPTransport
    TIMEOUT_ERRORS = [Net::OpenTimeout, Net::ReadTimeout, Net::WriteTimeout, ::Timeout::Error].freeze
    CONNECTION_ERRORS = [
      SystemCallError, IOError, SocketError, EOFError, OpenSSL::SSL::SSLError,
      Net::HTTPBadResponse, Net::ProtocolError
    ].freeze

    def initialize(max_idle: 16, keep_alive_timeout: 15, proxy: nil, net_http: {})
      @max_idle = max_idle
      @keep_alive_timeout = keep_alive_timeout
      @proxy = proxy.nil? ? nil : URI.parse(proxy.to_s)
      @net_http = net_http.to_h { |k, v| [:"#{k.to_s.delete_suffix('=')}=", v] }
      @net_http.each do |setter, value|
        raise ArgumentError, "net_http: Net::HTTP has no setting #{setter.to_s.chomp('=')}" unless Net::HTTP.method_defined?(setter)

        check_tls_setting(setter, value)
      end
      @idle = Hash.new { |h, k| h[k] = [] }
      @lock = Mutex.new
    end

    def call(method, url, headers, body, timeout)
      uri = URI.parse(url)
      http = checkout(uri, timeout)
      keep = false
      begin
        request = build_request(method, uri, headers, body)
        response = http.request(request)
        result = HTTPResponse.new(response.code.to_i, lower_headers(response), response.body.to_s)
        keep = !response["connection"].to_s.casecmp?("close")
        result
      rescue *TIMEOUT_ERRORS => e
        raise DecisionNode::TimeoutError, "no response within #{timeout} s (#{e.class})"
      rescue *CONNECTION_ERRORS => e
        raise DecisionNode::ConnectionError, "connection error: #{e.message} (#{e.class})"
      ensure
        keep ? checkin(uri, http) : discard(http)
      end
    end

    # Net::HTTP never follows a redirect on its own.
    def follow_redirects?
      false
    end

    # Closes every idle connection.
    def close
      conns = @lock.synchronize do
        all = @idle.values.flatten
        @idle.clear
        all
      end
      conns.each { |c| discard(c) }
    end

    private

    def key_for(uri)
      [uri.scheme, uri.host, uri.port]
    end

    def checkout(uri, timeout)
      http = @lock.synchronize { @idle[key_for(uri)].pop }
      http ||= new_http(uri)
      http.open_timeout = timeout
      http.read_timeout = timeout
      http.write_timeout = timeout
      http.ssl_timeout = timeout if http.use_ssl?
      begin
        http.start unless http.started?
      rescue *TIMEOUT_ERRORS => e
        raise DecisionNode::TimeoutError, "no connection within #{timeout} s (#{e.class})"
      rescue *CONNECTION_ERRORS => e
        raise DecisionNode::ConnectionError, "cannot connect to #{uri.host}: #{e.message} (#{e.class})"
      end
      http
    end

    def new_http(uri)
      http =
        if @proxy
          Net::HTTP.new(uri.host, uri.port, @proxy.host, @proxy.port, @proxy.user, @proxy.password)
        else
          Net::HTTP.new(uri.host, uri.port)
        end
      @net_http.each { |setter, value| http.public_send(setter, value) }
      # Set after the caller's settings, so none of them can turn TLS off.
      if uri.scheme == "https"
        http.use_ssl = true
        http.verify_mode = OpenSSL::SSL::VERIFY_PEER
        http.verify_hostname = true
        http.verify_callback = nil
      else
        http.use_ssl = false
      end
      http.max_retries = 0 # retries are the client's, so every attempt is counted
      http.keep_alive_timeout = @keep_alive_timeout
      http
    end

    def check_tls_setting(setter, value)
      name = setter.to_s.chomp("=")
      case name
      when "use_ssl"
        raise ArgumentError, "net_http: use_ssl is set from the URL and cannot be given"
      when "verify_mode"
        return if value == OpenSSL::SSL::VERIFY_PEER

        raise ArgumentError, "net_http: verify_mode must be OpenSSL::SSL::VERIFY_PEER; certificate checks cannot be turned off"
      when "verify_hostname"
        return if value == true

        raise ArgumentError, "net_http: verify_hostname cannot be turned off"
      when "verify_callback"
        raise ArgumentError, "net_http: verify_callback cannot be given; it could accept any certificate"
      end
    end

    def checkin(uri, http)
      overflow = @lock.synchronize do
        list = @idle[key_for(uri)]
        if list.size < @max_idle
          list.push(http)
          nil
        else
          http
        end
      end
      discard(overflow) if overflow
    end

    def discard(http)
      http.finish if http&.started?
    rescue StandardError
      nil
    end

    def build_request(method, uri, headers, body)
      path = uri.request_uri
      request =
        case method
        when "GET" then Net::HTTP::Get.new(path)
        when "POST" then Net::HTTP::Post.new(path)
        when "PUT" then bare(Net::HTTP::Put.new(path))
        when "DELETE" then Net::HTTP::Delete.new(path)
        else raise ArgumentError, "unsupported method #{method}"
        end
      headers.each { |name, value| request[name] = value }
      if body
        request.body = body
      elsif request.request_body_permitted?
        # A POST without a body (finalize, cancel) goes out with Content-Length 0
        # and no Content-Type, rather than the form type Net::HTTP would add.
        request.content_length = 0
        request.define_singleton_method(:request_body_permitted?) { false }
      end
      request
    end

    # A storage PUT carries exactly the headers it is given: none of the
    # defaults Net::HTTP adds on its own.
    def bare(request)
      %w[accept accept-encoding user-agent].each { |name| request.delete(name) }
      request
    end

    def lower_headers(response)
      response.each_header.each_with_object({}) { |(k, v), h| h[k.downcase] = v }
    end
  end
end
