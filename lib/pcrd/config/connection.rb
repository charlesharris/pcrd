# frozen_string_literal: true

module Pcrd
  module Config
    Connection = Data.define(:host, :port, :database, :user, :password)
  end
end
