# frozen_string_literal: true

require "bundler/setup"
require "benchmark/ips"
require "octorail"
require "trailblazer/operation"
require "trailblazer/macro"
require "yaso"
require "decouplio"

require_relative "operations/create_user"
require_relative "operations/ten_steps"
require_relative "operations/wrapped"
require_relative "operations/nested"

LIBS = %i[Poro Octorail Yaso Decouplio Trailblazer].freeze
VALID = { params: { email: "a@b.c" } }.freeze
INVALID = { params: { email: nil } }.freeze

SCENARIOS = {
  "CreateUser, success path" => [CreateUser, VALID, true],
  "CreateUser, failure on 1st step" => [CreateUser, INVALID, false],
  "10 simple steps" => [TenSteps, {}, true],
  "wrap (no-op transaction around 2 steps)" => [Wrapped, VALID, true],
  "nested operation, success path" => [Nested, VALID, true],
  "nested operation, failure inside" => [Nested, INVALID, false]
}.freeze

# Each library's way of calling an operation and reading its outcome.
def invoke(lib, klass, input)
  case lib
  when :Trailblazer then klass.call(**input)
  when :Yaso then klass.call(input.dup)
  else klass.call(**input)
  end
end

def ctx_of(lib, result)
  case lib
  when :Trailblazer then result.to_hash
  when :Yaso then result.to_h
  when :Decouplio then result.ctx
  else result.ctx
  end
end

def check!(lib, klass, input, success)
  result = invoke(lib, klass, input)
  ctx = ctx_of(lib, result)
  return if result.success? == success && (success ? ctx.key?(:notified) || ctx.key?(:ten) : ctx[:logged])

  abort "#{klass}: wrong outcome (success?=#{result.success?}, ctx=#{ctx.inspect})"
end

def allocations(lib, klass, input, calls: 10_000)
  calls.times { invoke(lib, klass, input) }
  GC.disable
  before = GC.stat(:total_allocated_objects)
  calls.times { invoke(lib, klass, input) }
  (GC.stat(:total_allocated_objects) - before) / calls.to_f
ensure
  GC.enable
end

puts "#{RUBY_DESCRIPTION}"
puts "YJIT: #{defined?(RubyVM::YJIT) && RubyVM::YJIT.enabled? ? "on" : "off"}"

# BENCH_ONLY=nested runs only the scenarios whose title contains that text.
only = ENV.fetch("BENCH_ONLY", nil)

SCENARIOS.each do |title, (namespace, input, success)|
  next if only && !title.include?(only)

  classes = LIBS.to_h { |lib| [lib, namespace.const_get(lib)] }
  classes.each { |lib, klass| check!(lib, klass, input, success) }

  puts "\n=== #{title}"
  puts "allocated objects per call:"
  classes.each { |lib, klass| puts format("  %-12s %6.1f", lib, allocations(lib, klass, input)) }

  Benchmark.ips do |x|
    x.config(warmup: 1, time: 3)
    classes.each { |lib, klass| x.report(lib.to_s) { invoke(lib, klass, input) } }
    x.compare!
  end
end
