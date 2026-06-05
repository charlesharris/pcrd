# frozen_string_literal: true

require_relative "lib/pcrd/version"

Gem::Specification.new do |spec|
  spec.name = "pcrd"
  spec.version = Pcrd::VERSION
  spec.authors = ["Charles Harris"]
  spec.email = ["charris000@gmail.com"]

  spec.summary = "PostgreSQL Column Rewrite Daemon — zero-downtime cross-cluster schema migrations"
  spec.description = <<~DESC
    pcrd migrates PostgreSQL tables to a new cluster using logical replication,
    with support for column type changes, renames, additions, drops, and column
    reordering with padding optimization. Designed for large tables where
    ALTER TABLE would cause unacceptable downtime.
  DESC
  spec.homepage = "https://github.com/charris/pcrd"
  spec.required_ruby_version = ">= 3.2.0"

  spec.files = Dir["lib/**/*", "bin/*", "README.md"]
  spec.executables = ["pcrd"]
  spec.require_paths = ["lib"]

  spec.add_dependency "pg",              "~> 1.5"
  spec.add_dependency "thor",            "~> 1.3"
  spec.add_dependency "sqlite3",         "~> 2.1"
  spec.add_dependency "tty-table",       "~> 0.12"
  spec.add_dependency "tty-progressbar", "~> 0.18"
  spec.add_dependency "pastel",          "~> 0.8"
  spec.add_dependency "zeitwerk",        "~> 2.6"
  spec.add_dependency "dry-schema",      "~> 1.13"
end
