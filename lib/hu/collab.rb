require 'powerbar'
require 'yaml'
require 'hashdiff'
require 'platform-api'

module Hu
  class Cli < Optix::Cli
    class Collab < Optix::Cli

      desc "Print current mapping to stdout"
      opt :format, "yaml|json", :default => 'yaml'
      parent "collab", "Application collaborators"
      def export(cmd, opts, argv)
        puts heroku_state.send("to_#{opts[:format]}".to_sym)
      end

      OP_COLORS = {
        '+' => "\e[0;1;32m",
        '-' => "\e[0;1;31m",
        '~' => "\e[0;32m",
      }
      desc "Read mapping from stdin and diff to heroku state"
      parent "collab"
      def diff(cmd, opts, argv)
        parsed_state = parse_as_json_or_yaml(STDIN.read)
        plan(HashDiff.diff(heroku_state, parsed_state)).each do |s|
          color = OP_COLORS[s[:op]]
          msg = ''
          if s[:method].nil?
            color = "\e[0;41;33;1m"
            msg = "Can not resolve this."
          end
          printf "%s%6s %-30s %-15s %-30s %s\e[0m\n", color, s[:op_name], s[:app_name], s[:role], s[:value], msg
        end
      end

      OP_MAP = {
        '+' => 'add',
        '-' => 'remove',
        '~' => 'change',
      }
      def plan(diff)
        plan = []
        diff.each do |op, target, value|
          app_name, role = target.split('.')
          role = role.split('[')[0]
          op_name = OP_MAP[op]
          method_name = "op_#{op_name}_#{role}".to_sym
          plan << {
            app_name: app_name,
            op: op,
            op_name: op_name,
            method: self.respond_to?(method_name) ? method_name : nil,
            value: value,
            role: role,
          }
        end
        plan
      end

      def op_add_collaborators(name)
        raise NotImplementedError
      end

      def op_remove_collaborators(name)
        raise NotImplementedError
      end

      def parse_as_json_or_yaml(input)
        begin
          parsed = JSON.load(input)
        rescue => jex
          begin
            parsed = YAML.load(input)
            if parsed.is_a? String
              raise ArgumentError, "Input parsed as YAML yields a String"
            end
          rescue => yex
            STDERR.puts "Error: Could neither parse stdin as YAML nor as JSON."
            STDERR.puts "-- JSON Error --"
            STDERR.puts jex
            STDERR.puts "-- YAML Error --"
            STDERR.puts yex
            raise ArgumentError
          end
        end
        parsed
      end

      def heroku_state
        data = {}
        app_names = h.app.list.map{|e| e['name']}
        app_names.each_with_index do |app_name,i|
          pb :msg => app_name, :total => app_names.length, :done => i+1
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
        pb :wipe
        data
      end

      def h
        @h ||= PlatformAPI.connect_oauth(Hu::Cli::API_TOKEN)
      end

      def pb(show_opts)
        return if $quiet
        @pb ||= PowerBar.new
        show_opts == :wipe ? @pb.wipe : @pb.show(show_opts)
      end

    end
  end
end
