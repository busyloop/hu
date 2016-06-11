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

module Hu
  class Cli < Optix::Cli
    Optix.command do
      text "Hu v#{Hu::VERSION} - Heroku Utility - https://github.com/busyloop/hu"
      opt :quiet, 'Quiet mode (no progress output)', default: false
      opt :version, 'Print version and exit', short: :none
      trigger :version do
        puts "Hu v#{Hu::VERSION}"
      end
      filter do |_cmd, opts, _argv|
        $quiet = opts[:quiet]
        $quiet = true unless STDOUT.isatty
      end
    end
  end
end
