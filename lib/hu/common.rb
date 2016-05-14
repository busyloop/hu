module Hu
  API_TOKEN = ENV['HEROKU_API_KEY'] || ENV['HEROKU_API_TOKEN'] || Netrc.read['api.heroku.com']&.password
end

class String
  def strip_heredoc
    indent = scan(/^[ \t]*(?=\S)/).min&.size || 0
    gsub(/^[ \t]{#{indent}}/, '')
  end
end

