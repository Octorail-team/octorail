# frozen_string_literal: true

module Octorail
  module DSL
    # configure: per-operation settings over the global Octorail.config (docs/configuration.md).
    # Allowed in an abstract! base too: these are settings, not flow.
    module Settings
      def configure(**settings)
        settings.each do |key, value|
          unless Config::OPERATION_SETTINGS.key?(key)
            raise ArgumentError, "#{self}: configure: unknown setting #{key.inspect}, " \
                                 "allowed: #{Octorail.key_list(Config::OPERATION_SETTINGS.keys)}"
          end

          own_settings[key] = Config.check!(key, value, "#{self}: configure")
        end
        invalidate!
        nil
      end

      # The operation's own value, else the nearest ancestor's, else the global one.
      def setting(key)
        return own_settings[key] if own_settings.key?(key)
        return superclass.setting(key) if superclass.respond_to?(:setting)

        Octorail.config.public_send(key)
      end

      private

      def own_settings = @own_settings ||= {}
    end
  end
end
