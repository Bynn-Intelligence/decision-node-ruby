# frozen_string_literal: true

require "minitest/autorun"
require "json"
require "decisionnode"

# A transport that answers from a list of canned responses and records each call.
class FakeHTTP
  Call = Struct.new(:method, :url, :headers, :body, :timeout) do
    def json
      JSON.parse(body)
    end
  end

  attr_reader :calls

  def follow_redirects?
    false
  end

  # Each step is an HTTPResponse, an exception to raise, or a Proc taking the Call.
  def initialize(*steps)
    @steps = steps
    @calls = []
    @lock = Mutex.new
  end

  def call(method, url, headers, body, timeout)
    call = Call.new(method, url, headers, body, timeout)
    step = @lock.synchronize do
      @calls << call
      @steps.size > 1 ? @steps.shift : @steps.first
    end
    step = step.call(call) if step.is_a?(Proc)
    raise step if step.is_a?(Exception)

    step
  end

  def self.json(status, body, headers = {})
    DecisionNode::HTTPResponse.new(status, { "content-type" => "application/json" }.merge(headers),
                                   body.is_a?(String) ? body : JSON.generate(body))
  end
end

module ClientHelpers
  ENV_VARS = %w[DECISIONNODE_API_KEY DECISIONNODE_BASE_URL DECISIONNODE_MODEL].freeze

  def setup
    @saved_env = ENV_VARS.to_h { |v| [v, ENV.delete(v)] }
  end

  def teardown
    @saved_env.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
  end

  def client(http, **kw)
    dn = DecisionNode.new(api_key: "dn_test_key", base_url: "https://api.example.test", http_client: http, **kw)
    sleeps = []
    dn.instance_variable_set(:@sleeper, ->(s) { sleeps << s })
    dn.define_singleton_method(:sleeps) { sleeps }
    dn
  end

  def truth_body(value = 0.5, id: "q")
    { "model" => "decisionnode-1.0", "answers" => { id => { "type" => "truth", "truth" => value } },
      "usage" => { "input_tokens" => 5, "output_tokens" => 0 } }
  end
end
