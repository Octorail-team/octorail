# frozen_string_literal: true

require_relative "lib/octorail/version"

Gem::Specification.new do |spec|
  spec.name = "octorail"
  spec.version = Octorail::VERSION
  spec.authors = ["Dmytro Bereza"]
  spec.email = ["dmitrybereza2001@gmail.com"]

  spec.summary = "Lightweight railway-oriented operations compiled to plain Ruby at load time."
  spec.description = <<~DESC
    Octorail provides a strict, Trailblazer-like railway DSL (step, pass,
    failure, wrap, nested, switch, recover) that is compiled into a plain Ruby
    method when the operation is first used, so a call costs about as much as
    hand-written code. Optional tracing shows the path a call took.
  DESC
  spec.homepage = "https://github.com/Octorail-team/octorail"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.3"

  spec.metadata["source_code_uri"] = spec.homepage
  spec.metadata["changelog_uri"] = "#{spec.homepage}/blob/main/CHANGELOG.md"
  spec.metadata["documentation_uri"] = "#{spec.homepage}/tree/main/docs"
  spec.metadata["bug_tracker_uri"] = "#{spec.homepage}/issues"
  spec.metadata["rubygems_mfa_required"] = "true"

  spec.files = Dir["lib/**/*.rb", "README.md", "CHANGELOG.md", "LICENSE.txt"]
  spec.require_paths = ["lib"]
end
