# frozen_string_literal: true

module Hu
  class Cli < Optix::Cli
    # Heroku Scale
    class Scale < Optix::Cli
      DYNO_TYPES = [
        {
          id: 'free',
          sleeps: true,
          pro: false,
          ram: 512,
          cpu: 1,
          dedicated: false,
          usd: 0,
          letter: 'f',
          color: "\e[0;32;1m",
        },
        {
          id: 'hobby',
          sleeps: false,
          pro: false,
          ram: 512,
          cpu: 1,
          dedicated: false,
          usd: 7,
          letter: 'H',
          color: "\e[0;32m",
        },
        {
          id: 'standard-1x',
          sleeps: false,
          pro: true,
          ram: 512,
          cpu: 1,
          dedicated: false,
          usd: 25,
          letter: '1',
          color: "\e[0;33m",
        },
        {
          id: 'standard-2x',
          sleeps: false,
          pro: true,
          ram: 1024,
          cpu: 4,
          dedicated: false,
          usd: 50,
          letter: '2',
          color: "\e[0;33;1m",
        },
        {
          id: 'performance-m',
          sleeps: false,
          pro: true,
          ram: 2560,
          cpu: 11,
          dedicated: true,
          usd: 250,
          letter: 'M',
          color: "\e[0;31;1m",
        },
        {
          id: 'performance-l',
          sleeps: false,
          pro: true,
          ram: 14_336,
          cpu: 46,
          dedicated: true,
          usd: 500,
          letter: 'L',
          color: "\e[0;35;1m",
        }
      ].freeze

      DYNO_TYPES.each_with_index do |dt, i|
        dt[:index] = i
      end

      text 'Print dyno formation.'
      desc 'Print dyno formation'
      if Hu::API_TOKEN.nil?
        text ''
        text "\e[1mWARNING: Environment variable 'HEROKU_API_KEY' must be set.\e[0m"
      end
      filter do |_cmd, _opts, _argv|
        if Hu::API_TOKEN.nil?
          STDERR.puts "\e[0;31;1mERROR: Environment variable 'HEROKU_API_KEY' must be set.\e[0m"
          exit 1
        end
        require 'yaml'
        require 'platform-api'
        require 'rainbow'
        require 'rainbow/ext/string'
      end

      def scale(_cmd, _opts, _args)
        print_types
        puts
        print_state heroku_state
      end

      def print_types
        cols = %w(id ram cpu dedicated sleeps usd)
        tpl  = "%-16s %5s %4s %11s %7s %5s\n"
        puts
        puts ' Available Dyno Types '.inverse
        puts
        printf tpl.bright, *cols
        DYNO_TYPES.each do |dyno_type|
          printf tpl, *cols.map { |col| dyno_type[col.to_sym] }
        end
      end

      def print_state(state)
        cols = ['$/mo', 'fH12ML', 'formation']
        rows = []

        total_cost = 0
        max_app_name_len = state.keys.reduce(0) { |a, e| [a, e.length].max }
        state.sort.each do |app_name, dyno_types|
          next if ignored_app?(app_name)
          row = { 'app' => app_name, 'fH12ML' => '......', 'formation' => "\e[0mheroku ps:scale -a #{app_name.ljust(max_app_name_len).color(:green).bright}" }
          cost = 0
          dyno_types.each do |dyno_type, dynos|
            dynos.each do |dyno|
              row = Marshal.load(Marshal.dump(row))
              dyno_type_str = dyno[:type]
              quant_colon_type = "#{dyno[:quantity]}:#{dyno_type}"
              if dyno[:quantity] == 0
                dyno_type_str = dyno_type_str.color(:black).bright
                quant_colon_type = quant_colon_type.color(:black).bright
              else
                dyno_type_str = dyno_type_str.color(:yellow)
                quant_colon_type = quant_colon_type.color(:yellow)
                idx = DYNO_TYPES.find { |e| e[:id] == dyno_type }[:index]
                row['fH12ML'][idx] = 'fH12ML'[idx]
              end
              row['formation'] += " #{dyno_type_str}" + '='.color(:black).bright + quant_colon_type.to_s
              cost += DYNO_TYPES.find { |e| e[:id] == dyno_type }[:usd] * dyno[:quantity]
            end
          end
          new_row = ''.dup
          row['fH12ML'].each_char do |l|
            new_row << (DYNO_TYPES.find {|dt| dt[:letter] == l}[:color] + l + "\e[0;30;1m" rescue '.')
          end
          row['fH12ML'] = "\e[0;30;1m"+new_row
          total_cost += cost
          row['$/mo'] = format '%4d', cost
          rows << row
        end

        puts
        puts ' Current Dyno Formation '.inverse
        puts

        tpl = "%-5s %6s %s\n"
        printf tpl.bright, *cols
        rows.each do |row|
          printf tpl, *cols.map { |col| row[col] }
        end
        puts
        puts "Total: $#{total_cost} USD/mo"
        puts
      end

      def ignored_app?(app_name)
        ENV.fetch('HU_IGNORE_APPS', '').split(' ').each do |p|
          return true if File.fnmatch(p, app_name)
        end
        false
      end

      def heroku_state(force_refresh = false)
        return @heroku_state unless force_refresh || @heroku_state.nil?
        data = {}
        app_names = h.app.list.map { |e| e['name'] }.reject { |e| ignored_app?(e) }
        threads = []
        app_names.each_with_index do |app_name, _i|
          threads << Thread.new do
            h.formation.list(app_name).each do |dyno|
              dyno_size = dyno['size'].downcase
              data[app_name] ||= {}
              data[app_name][dyno_size] ||= []
              data[app_name][dyno_size] << { type: dyno['type'], quantity: dyno['quantity'] }
            end
          end
        end
        threads.each_with_index do |t, _i|
          t.join
        end
        @heroku_state = data
      end

      def h
        @h ||= PlatformAPI.connect_oauth(Hu::API_TOKEN)
      end
    end
  end
end
