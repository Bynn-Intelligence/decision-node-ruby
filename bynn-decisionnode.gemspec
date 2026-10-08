# frozen_string_literal: true

require_relative "lib/decisionnode/version"

Gem::Specification.new do |spec|
  spec.name = "bynn-decisionnode"
  spec.version = DecisionNode::VERSION
  spec.authors = ["Bynn Intelligence, Inc."]
  spec.summary = "Ruby client for the DecisionNode API."
  spec.description = "A typed client for DecisionNode: ask truth, choice, score and number questions " \
                     "about any state and get calibrated answers back, with image uploads, " \
                     "sessions, the Batch API, retries, typed errors and the safety check result."
  spec.homepage = "https://decisionnode.com"
  spec.license = "MIT"
  spec.metadata["source_code_uri"] = "https://github.com/Bynn-Intelligence/decision-node-ruby"
  spec.metadata["changelog_uri"] = "https://github.com/Bynn-Intelligence/decision-node-ruby/blob/main/CHANGELOG.md"
  spec.metadata["rubygems_mfa_required"] = "true"

  spec.required_ruby_version = ">= 3.2"
  spec.files = Dir["lib/**/*.rb"] + %w[README.md CHANGELOG.md LICENSE]
  spec.require_paths = ["lib"]

  # Net::HTTP, JSON, Digest and OpenSSL from the standard library; the
  # WebSocket protocol of sessions from websocket-driver, loaded on the first
  # session only.
  spec.add_dependency "websocket-driver", "0.8.2"
end
