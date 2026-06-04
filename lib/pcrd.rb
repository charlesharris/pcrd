# frozen_string_literal: true

require "zeitwerk"

loader = Zeitwerk::Loader.for_gem
loader.inflector.inflect "cli" => "CLI"
loader.inflector.inflect "ddl" => "DDL"
loader.setup

module Pcrd
end
