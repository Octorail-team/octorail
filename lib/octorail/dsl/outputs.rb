# frozen_string_literal: true

module Octorail
  module DSL
    # output: the operation's declared public result keys.
    module Outputs
      def output(*names)
        check_not_abstract!("output #{names.map(&:inspect).join(", ")}")
        names.each do |name|
          check_output!(name)
          own_outputs << name unless outputs.include?(name)
          # A subclass that declared it already now inherits it instead.
          descendants.each { |subclass| subclass.__send__(:own_outputs).delete(name) }
        end
        invalidate!
        nil
      end

      def outputs
        parent = superclass.respond_to?(:outputs) ? superclass.outputs : []
        parent + own_outputs
      end

      private

      def own_outputs = @own_outputs ||= []

      def check_output!(name)
        check_name!(name, "output")
        return unless Result::BUILTIN_KEYS.include?(name) || Result.method_defined?(name) ||
                      Result.private_method_defined?(name)

        raise ArgumentError, "#{self}: output #{name.inspect} collides with a Result field or method"
      end
    end
  end
end
