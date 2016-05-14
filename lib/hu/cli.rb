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
    Optix::command do
      text "Hu v#{Hu::VERSION} - Heroku Utility"
      opt :quiet, "Quiet mode (no progress output)", :default => false
      opt :version, "Print version and exit", :short => :none
      trigger :version do
        puts "Hu v#{Hu::VERSION}"
      end
      filter do |cmd, opts, argv|
        $quiet = opts[:quiet]
        $quiet = true unless STDOUT.isatty
      end
    end
  end
end

