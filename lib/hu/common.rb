# frozen_string_literal: true
require 'blackbox/gem'
require 'config'

module Hu
  API_TOKEN = ENV['HEROKU_API_KEY'] || ENV['HEROKU_API_TOKEN'] || Netrc.read['api.heroku.com']&.password
  CONFIG_FILE = File.join(ENV['HOME'], '.hu.yaml')
end

class String
  def strip_heredoc
    indent = scan(/^[ \t]*(?=\S)/).min&.size || 0
    gsub(/^[ \t]{#{indent}}/, '')
  end
end

Config.load_and_set_settings Hu::CONFIG_FILE

begin
  unless ENV['SKIP_VERSION_CHECK']
    version_info = BB::Gem.version_info(check_interval: 900)
    if version_info[:gem_update_available]
      puts
      puts "\e[33;1mWoops! \e[0mA newer version of #{version_info[:gem_name]} is available."
      puts "       Please type '\e[1mgem install #{version_info[:gem_name]}\e[0m' to upgrade (v#{version_info[:gem_installed_version]} -> v#{version_info[:gem_latest_version]})."
      sleep 1
      puts
      exit 1
    end
  end
rescue
end
