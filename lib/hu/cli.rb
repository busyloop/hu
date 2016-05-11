require 'hu/version'
require 'optix'
require 'powerbar'
require 'yaml'
require 'platform-api'

require 'hu/collab'
require 'hu/deploy'

module Hu
  class Cli < Optix::Cli
    API_TOKEN = ENV['HEROKU_API_KEY'] || ENV['HEROKU_API_TOKEN']
    Optix::command do
      text "Hu v#{Hu::VERSION} - Heroku Utility"
      if API_TOKEN.nil?
        text ""
        text "\e[1mWARNING: Environment variable 'HEROKU_API_KEY' must be set.\e[0m"
      end
      opt :quiet, "Don't show progress bar", :default => false
      opt :version, "Print version and exit", :short => :none
      trigger :version do
        puts "Hu v#{Hu::VERSION}"
      end
      filter do
        if API_TOKEN.nil?
          STDERR.puts "\e[0;31;1mERROR: Environment variable 'HEROKU_API_KEY' must be set.\e[0m"
          exit 1
        end
      end
      filter do |cmd, opts, argv|
        $quiet = opts[:quiet]
        $quiet = true unless STDOUT.isatty
      end
    end
  end
end

