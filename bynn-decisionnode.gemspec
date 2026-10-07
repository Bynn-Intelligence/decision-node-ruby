# frozen_string_literal: true

require_relative "lib/decisionnode/version"

Gem::Specification.new do |spec|
  spec.name = "bynn-decisionnode"
  spec.version = DecisionNode::VERSION
  spec.authors = ["Bynn Intelligence, Inc."]
  spec.summary = "Ruby client for the DecisionNode API."
  spec.description = "A typed client for DecisionNode: ask truth, choice and score questions " \
                     "about any state and get calibrated answers back, with retries, typed " \
                     "errors and the safety check result."
  spec.homepage = "https://decisionnode.com"
  spec.license = "MIT"
  spec.metadata["source_code_uri"] = "https://github.com/Bynn-Intelligence/decision-node-ruby"
  spec.metadata["changelog_uri"] = "https://github.com/Bynn-Intelligence/decision-node-ruby/blob/main/CHANGELOG.md"
  spec.metadata["rubygems_mfa_required"] = "true"

  spec.required_ruby_version = ">= 3.2"
  spec.files = Dir["lib/**/*.rb"] + %w[README.md CHANGELOG.md LICENSE]
  spec.require_paths = ["lib"]

  # No runtime dependencies: Net::HTTP and JSON from the standard library.
end
