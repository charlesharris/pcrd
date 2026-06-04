# frozen_string_literal: true

require_relative "boot"

require "rails"
require "active_model/railtie"
require "active_record/railtie"
require "action_controller/railtie"
require "action_dispatch/railtie"

Bundler.require(*Rails.groups)

module ListingsApp
  class Application < Rails::Application
    config.load_defaults 7.1
    config.api_only = true

    # Stream logs to stdout for Docker
    config.logger = ActiveSupport::Logger.new($stdout)
    config.log_level = :info
  end
end
