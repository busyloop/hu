require 'blackbox/gem'

module Hu
  API_TOKEN = ENV['HEROKU_API_KEY'] || ENV['HEROKU_API_TOKEN'] || Netrc.read['api.heroku.com']&.password
end

class String
  def strip_heredoc
    indent = scan(/^[ \t]*(?=\S)/).min&.size || 0
    gsub(/^[ \t]{#{indent}}/, '')
  end
end

version_info = BB::Gem.version_info(check_interval: 900)
unless version_info[:installed_is_latest] == true
  puts "\e[33;1mWARNING: \e[0mA newer version of #{version_info[:gem_name]} is available."
  puts "         Please type '\e[1mgem install #{version_info[:gem_name]}\e[0m' to upgrade (v#{version_info[:gem_installed_version]} -> v#{version_info[:gem_latest_version]})."
  sleep 1
end
