require 'powerbar'
require 'yaml'
require 'hashdiff'
require 'set'
require 'platform-api'

module Hu
  class Cli < Optix::Cli
    class Collab < Optix::Cli

      text "Manage application/collaborator mapping."
      text ""
      text "Start by exporting the current mapping,"
      text "edit to taste, then diff and import."
      text ""
      text "WARNING: If you remove yourself from an application"
      text "         then hu won't be able to see it anymore."
      text ""
      text "Please note that hu can only operate on applications and"
      text "collaborators that it sees. It will stubbornly refuse to"
      text "create new applications or collaborators."
      text ""
      text "Follow this procedure to introduce a new collaborator:"
      text ""
      text "1. Create collaborator on heroku (via web or toolbelt)"
      text "2. Add them to at least one application that you have access to"
      text ""
      text "Now the new collaborator will show up in 'export'"
      text "and may be assigned to applications."
      def collab; end

      OP_COLORS = {
        '+' => "\e[0;1;32m",
        '-' => "\e[0;1;31m",
        '~' => "\e[0;32m",
      }
      desc "Read mapping from stdin and diff to heroku state"
      text "Read mapping from stdin and diff to heroku state"
      parent "collab"
      def diff(cmd, opts, argv)
        parsed_state = parse_as_json_or_yaml(STDIN.read)
        plan(HashDiff.diff(heroku_state['apps'], parsed_state['apps'])).each do |s|
          color = OP_COLORS[s[:op]]
          msg = ''
          if s[:method].nil?
            color = "\e[0;41;33;1m"
            msg = "Can not resolve this."
          end
          STDERR.printf "%s%6s %-30s %-15s %-30s %s\e[0m\n", color, s[:op_name], s[:app_name], s[:role], s[:value], msg
        end
      end

      desc "Print current mapping to stdout"
      text "Print current mapping to stdout"
      opt :format, "yaml|json", :default => 'yaml'
      parent "collab", "Application collaborators"
      def export(cmd, opts, argv)
        puts heroku_state.send("to_#{opts[:format]}".to_sym)
      end

      desc "Read mapping from stdin and push to heroku"
      text "Read mapping from stdin and push to heroku"
      parent "collab"
      def import(cmd, opts, argv)
        parsed_state = parse_as_json_or_yaml(STDIN.read)
        plan(HashDiff.diff(heroku_state['apps'], parsed_state['apps'])).each do |s|
          color = OP_COLORS[s[:op]]
          msg = ''
          icon = ' '
          eol = "\e[100D"
          if s[:method].nil?
            color = "\e[0;41;33;1m"
            msg = "Skipped."
            icon = "\e[0;31;1m\u2718\e[0m" # X
            eol = "\n"
          end
          STDERR.printf "%s %s%6s %-30s %-15s %-30s %s\e[0m%s", icon, color, s[:op_name], s[:app_name], s[:role], s[:value], msg, eol
          next if s[:method].nil?
          begin
            self.send(s[:method], s)
            STDERR.puts "\e[0;32;1m\u2713\e[0m\n" # check
          rescue => e
            STDERR.puts "\e[0;31;1m\u2718\e[0m\n" # X
            puts e.inspect
            puts e.backtrace
            exit 1
          end
        end
      end

      OP_MAP = {
        '+' => 'add',
        '-' => 'remove',
        '~' => 'change',
      }
      def plan(diff)
        plan = []
        diff.each do |op, target, lval, rval|
          value = rval || lval
          app_name, role = target.split('.')

          role = role.split('[')[0] unless role.nil?
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

      def op_add_collaborators(args)
        h.collaborator.create(args[:app_name], :user => args[:value])
      end

      def op_remove_collaborators(args)
        h.collaborator.delete(args[:app_name], args[:value])
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
        normalize(parsed)
      end

      def normalize(parsed)
        unless parsed.include? 'apps'
          raise ArgumentError, "Malformed input, key 'apps' not found."
        end
        parsed['apps'].each do |app_name, v|
          unless heroku_state['apps'].include? app_name
            raise ArgumentError, "Unknown application: #{app_name}"
          end
          next unless v['collaborators'].is_a? Array
          v['collaborators'].flatten!.sort!.each do |collab|
            unless heroku_state['collaborators'].include? collab
              raise ArgumentError, "Unknown collaborator: #{collab}"
            end
          end
        end
        parsed
      end

      def heroku_state(force_refresh=false)
        return @heroku_state unless force_refresh or @heroku_state.nil?
        all_collaborators = Set.new
        data = { 'apps' => {} }
        app_names = h.app.list.map{|e| e['name']}
        app_names.each_with_index do |app_name,i|
          pb :msg => app_name, :total => app_names.length, :done => i+1
          d = data['apps'][app_name] = { 'collaborators' => [] }
          h.collaborator.list(app_name).map{|e|
            case e['role']
            when 'owner'
              d['owner'] = e['user']['email']
            when nil
              d['collaborators'] << e['user']['email']
            else
              raise RuntimeError, "Unknown collaborator role: #{e['role']}"
            end
            all_collaborators << e['user']['email']
          }
        end
        pb :wipe
        data['collaborators'] = all_collaborators.to_a.sort
        @heroku_state = data
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
