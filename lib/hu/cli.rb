require 'hu/version'
require 'optix'
require 'powerbar'
require 'yaml'
require 'platform-api'

module Hu
  class Cli < Optix::Cli
    API_TOKEN = ENV['HEROKU_API_TOKEN']
    cli_root do
      text "Hu v#{Hu::VERSION} - Heroku Utility"
      if API_TOKEN.nil?
        text ""
        text "\e[1mWARNING: Environment variable 'HEROKU_API_TOKEN' must be set.\e[0m"
      end
      opt :version, "Print version and exit", :short => :none
      trigger :version do
        puts "Hu v#{Hu::VERSION}"
      end
      filter do
        if API_TOKEN.nil?
          STDERR.puts "\e[0;31;1mERROR: Environment variable 'HEROKU_API_TOKEN' must be set.\e[0m"
          exit 1
        end
      end
    end

    desc "Export current collaborator mapping"
    opt :format, "yaml|json", :default => 'yaml'
    parent "collab", "Application collaborators"
    def export(cmd, opts, argv)
      #raise Optix::HelpNeeded unless opts.values_at(:capslock, :numlock, :verbose).any?
      data = {}
      pb = PowerBar.new
      app_names = h.app.list.map{|e| e['name']}
      app_names.each_with_index do |app_name,i|
        pb.show :msg => app_name, :total => app_names.length, :done => i
        data[app_name] = { 'collaborators' => [] }
          h.collaborator.list(app_name).map{|e|
            case e['role']
            when 'owner'
              data[app_name]['owner'] = e['user']['email']
            when nil
              data[app_name]['collaborators'] << e['user']['email']
            else
              raise RuntimeError, "Unknown collaborator role: #{e['role']}"
            end
          }
      end
      pb.wipe
      puts data.send("to_#{opts[:format]}".to_sym)
    end

    def h
      @h ||= PlatformAPI.connect_oauth(API_TOKEN)
    end

  end
end
