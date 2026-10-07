# frozen_string_literal: true

require "rake/testtask"

Rake::TestTask.new(:test) do |t|
  t.libs << "lib" << "test"
  t.test_files = FileList["test/*_test.rb"].exclude("test/conformance_test.rb")
  t.warning = true
end

# Runs the language-neutral conformance suite against its mock server.
# Set DECISIONNODE_CONFORMANCE_DIR to a checkout of the suite.
Rake::TestTask.new(:conformance) do |t|
  t.libs << "lib" << "test"
  t.test_files = FileList["test/conformance_test.rb"]
  t.warning = true
end

task default: %i[test conformance]
