# frozen_string_literal: true

module Pcrd
  module Commands
    # Builds the target-readiness manifest by comparing source and target.
    # Read-only; does not modify either cluster.
    class Readiness
      def initialize(config, options = {})
        @config  = config
        @options = options
      end

      def run
        raise ConfigError, "target connection required for readiness" if @config.target.nil?
        raise ConfigError, "no tables configured" if (@config.migrate&.tables || []).empty?

        source = Connection::Pool.new(@config.source)
        target = Connection::Pool.new(@config.target)

        result = Pcrd::Readiness::Manifest.new(
          source_pool: source, target_pool: target, config: @config
        ).build

        source.close
        target.close
        result
      end
    end
  end
end
