# frozen_string_literal: true
require 'segment'
require 'tty-prompt'
require 'securerandom'

module Hu
  class Tm
    API_TOKEN = ENV['HEROKU_API_KEY'] || ENV['HEROKU_API_TOKEN'] || Netrc.read['api.heroku.com']&.password
    @segment = nil
    @context = {}

    class << self
      def t(event, props = {})
        return if @segment.nil?
        @segment.track(anonymous_id: Settings.userid,
                       event: event.to_s,
                       properties: props,
                       context: @context)
      end

      def flush!
        return if @segment.nil?
        @segment.flush
      end

      def start!
        if Settings.send_anonymous_usage_statistics.nil?
          puts <<-EOF.strip_heredoc

          Hu would like to collect anonymous usage
          statistics for the purpose of self-improvement.

          No personal data or identifying information
          about your projects will be collected.

          EOF

          prompt = TTY::Prompt.new
          choice = prompt.select('Enable anonymous usage statistics?') do |menu|
            menu.enum '.'
            menu.choice 'Yes, I will help Hu!', true
            menu.choice 'Nope', false
          end

          cfg = {
            userid: SecureRandom.uuid
          }
          begin
            cfg = YAML.parse(File.read(Hu::CONFIG_FILE))
          rescue
          end
          cfg['send_anonymous_usage_statistics'] = choice
          File.write(Hu::CONFIG_FILE, YAML.dump(cfg))

          puts "\nThanks!\n"
          puts "Your decision was saved to #{Hu::CONFIG_FILE}\n"
          sleep 3
        end

        if Settings.send_anonymous_usage_statistics == true
          @segment = Segment::Analytics.new(write_key: 'T32sCm68MMAsyoa9r5uPtHz0YwJ3MjXI')
          @context = { version: Hu::VERSION }
          @segment.identify(anonymous_id: Settings.userid || SecureRandom.uuid,
                            context: @context)
        end
      end
    end
  end
end

Hu::Tm.start!
