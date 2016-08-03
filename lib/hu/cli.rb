# frozen_string_literal: true
require 'hu/version'
require 'optix'
require 'powerbar'
require 'yaml'
require 'netrc'
require 'platform-api'

require 'hu/common'
require 'hu/collab'
require 'hu/deploy'
require 'hu/scale'

module Hu
  class Cli < Optix::Cli
    Optix.command do
      text "Hu v#{Hu::VERSION} - Heroku Utility - https://github.com/busyloop/hu"
      opt :version, 'Print version and exit', short: :none
      trigger :version do
        puts "Hu v#{Hu::VERSION}"
      end
    end
  end
end
