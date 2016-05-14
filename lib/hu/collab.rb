require 'powerbar'
require 'yaml'
require 'hashdiff'
require 'set'
require 'netrc'
require 'platform-api'

module Hu
  class Cli < Optix::Cli
    class Collab < Optix::Cli
      class InvalidOperation < StandardError; end
      class InvalidPlan < StandardError
        attr_accessor :invalid_plan

        def initialize(message=nil, invalid_plan=nil)
          super(message)
          self.invalid_plan = invalid_plan
        end
      end

      text "Manage application/collaborator mapping."
      text ""
      text "Start by exporting the current mapping,"
      text "edit to taste, then diff and import."
      text ""
      text "The environment variable HU_IGNORE_APPS"
      text "may contain space delimited glob(7) patterns"
      text "of apps to be ignored."
      text ""
      text "WARNING: If you remove yourself from an application"
      text "         then hu won't be able to see it anymore."
      if Hu::API_TOKEN.nil?
        text ""
        text "\e[1mWARNING: Environment variable 'HEROKU_API_KEY' must be set.\e[0m"
      end
      filter do
        if Hu::API_TOKEN.nil?
          STDERR.puts "\e[0;31;1mERROR: Environment variable 'HEROKU_API_KEY' must be set.\e[0m"
          exit 1
        end
      end
      def collab; end

      OP_COLORS = {
        '+' => "\e[0;1;32m",
        '-' => "\e[0;1;34m",
        '~' => "\e[0;32m",
      }
      desc "Read mapping from stdin and diff to heroku state"
      text "Read mapping from stdin and diff to heroku state"
      parent "collab"
      def diff(cmd, opts, argv)
        parsed_state = parse_as_json_or_yaml(STDIN.read)
        show_plan( plan(HashDiff.diff(heroku_state['apps'], parsed_state['apps']), opts) )
      end

      def show_plan(plan)
        plan.each do |s|
          color = OP_COLORS[s[:op]]
          msg = ''
          icon = ' '
          if s[:method].nil?
            color = "\e[0m"
            msg = "<-- Can not resolve this (NO-OP)"
            icon = "⚠️"
          elsif s[:invalid]
            color = "\e[0m"
            icon = "⚠️"
          end
          STDERR.printf "%1s %s%6s %-30s %-15s %-30s %s\e[0m\n", icon, color, s[:op_name], s[:app_name], s[:role], s[:value], msg
          if s[:invalid]
            STDERR.puts "\e[31;1m         Error: #{s[:invalid]}\e[0m\n\n"
          end
        end
      end

      desc "Print current mapping to stdout"
      text "Print current mapping to stdout"
      opt :format, "yaml|json", :default => 'yaml'
      parent "collab", "Manage application collaborators"
      def export(cmd, opts, argv)
        puts heroku_state.send("to_#{opts[:format]}".to_sym)
      end

      desc "Read mapping from stdin and push to heroku"
      text "Read mapping from stdin and push to heroku"
      opt :allow_create, "Create new collaborators on heroku", :short => 'c'
      opt :silent_create, "Suppress email invitation when creating collaborators"
      parent "collab"
      def import(cmd, opts, argv)
        parsed_state = parse_as_json_or_yaml(STDIN.read)
        validators = {
          :op_add_collaborators => Proc.new { |op|
            unless heroku_state['collaborators'].include? op[:value] or opts[:allow_create]
              raise InvalidOperation, "Use -c to allow creation of new collaborator '#{op[:value]}'"
            end
          }
        }
        begin
          plan(HashDiff.diff(heroku_state['apps'], parsed_state['apps']), opts, validators).each do |s|
            color = OP_COLORS[s[:op]]
            msg = ''
            icon = ' '
            eol = "\e[1G"
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
          end # /plan()
        rescue InvalidPlan => e
          STDERR.puts "\e[0;31;1m#{e}:\e[0m\n\n"
          show_plan(e.invalid_plan)
          exit 1
        end
      end

      OP_MAP = {
        '+' => 'add',
        '-' => 'remove',
        '~' => 'change',
      }
      def plan(diff, env={}, validators={})
        plan = []
        last_error = nil
        diff.each do |op, target, lval, rval|
          value = rval || lval
          app_name, role = target.split('.')

          role = role.split('[')[0] unless role.nil?
          op_name = OP_MAP[op]
          method_name = "op_#{op_name}_#{role}".to_sym
          operation = {
            app_name: app_name,
            op: op,
            op_name: op_name,
            method: self.respond_to?(method_name) ? method_name : nil,
            value: value,
            role: role,
            env: env,
          }
          if validators.include? method_name
            begin
              validators[method_name].call(operation)
            rescue InvalidOperation => e
              last_error = operation[:invalid] = e
            end
          end
          plan << operation
        end
        raise InvalidPlan.new("Plan did not pass validation", plan) unless last_error.nil?
        plan
      end

      def op_add_collaborators(args)
        h.collaborator.create(args[:app_name], :user => args[:value], :silent => args[:env][:silent_create])
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
        parsed['apps'].reject!{ |e| ignored_app?(e) }
        parsed['apps'].each do |app_name, v|
          unless heroku_state['apps'].include? app_name
            raise ArgumentError, "Unknown application: #{app_name}"
          end
          next unless v['collaborators'].is_a? Array
          v['collaborators'].flatten!
          v['collaborators'].sort!
        end
        parsed
      end

      def ignored_app?(app_name)
        ENV.fetch('HU_IGNORE_APPS','').split(' ').each do |p|
          return true if File.fnmatch(p, app_name)
        end
        false
      end

      def heroku_state(force_refresh=false)
        return @heroku_state unless force_refresh or @heroku_state.nil?
        all_collaborators = Set.new
        data = { 'apps' => {} }
        app_names = h.app.list.map{|e| e['name']}.reject{ |e| ignored_app?(e) }
        threads = []
        app_names.each_with_index do |app_name,i|
          threads << Thread.new do
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
        end
        threads.each_with_index do |t, i|
          t.join
          pb :msg => app_names[i], :total => app_names.length, :done => i+1
        end
        pb :wipe
        data['collaborators'] = all_collaborators.to_a.sort
        @heroku_state = data
      end

      def h
        @h ||= PlatformAPI.connect_oauth(Hu::API_TOKEN)
      end

      def pb(show_opts)
        return if $quiet
        @pb ||= PowerBar.new
        show_opts == :wipe ? @pb.wipe : @pb.show(show_opts)
      end

    end
  end
end
