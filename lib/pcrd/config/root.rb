# frozen_string_literal: true

module Pcrd
  module Config
    # Top-level config object returned by Config::Loader.load.
    # target, migrate, analyze, verify, cutover are all optional (may be nil).
    Root = Data.define(:source, :target, :migrate, :analyze, :verify, :cutover, :path)
  end
end
