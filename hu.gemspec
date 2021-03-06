# coding: utf-8
# frozen_string_literal: true
lib = File.expand_path('../lib', __FILE__)
$LOAD_PATH.unshift(lib) unless $LOAD_PATH.include?(lib)
require 'hu/version'

Gem::Specification.new do |spec|
  spec.name          = 'hu'
  spec.version       = Hu::VERSION
  spec.authors       = ['moe']
  spec.email         = ['moe@busyloop.net']
  spec.summary       = 'Heroku Utility.'
  spec.description   = 'Heroku Utility.'
  spec.homepage      = 'https://github.com/busyloop/hu'
  spec.license       = 'MIT'

  spec.files         = `git ls-files`.split($INPUT_RECORD_SEPARATOR)
  spec.executables   = spec.files.grep(%r{^bin/}) { |f| File.basename(f) }
  spec.test_files    = spec.files.grep(%r{^(test|spec|features)/})
  spec.require_paths = ['lib']
  spec.required_ruby_version = '>= 2.3.0'

  spec.add_development_dependency 'bundler', '~> 1.5'
  spec.add_development_dependency 'rake'
  spec.add_development_dependency 'bump'

  spec.add_dependency 'optix', '~> 2.0.0'
  spec.add_dependency 'blackbox', '~> 4.0.2'
  spec.add_dependency 'excon', '= 0.62.0'
  spec.add_dependency 'platform-api', '~> 2.1.0'
  spec.add_dependency 'powerbar', '>= 1.0.16'
  spec.add_dependency 'hashdiff', '~> 0.3.0'
  spec.add_dependency 'version_sorter', '~> 2.2.0'
  spec.add_dependency 'versionomy', '~> 0.5.0'
  spec.add_dependency 'tty-prompt', '~> 0.13.2'
  spec.add_dependency 'tty-spinner', '= 0.3.0'
  spec.add_dependency 'tty-table', '~> 0.10.0'
  spec.add_dependency 'fidget', '~> 0.0.6'
  spec.add_dependency 'octokit'
  spec.add_dependency 'faraday', '= 0.17.0'
  spec.add_dependency 'tty-cursor'
  spec.add_dependency 'rainbow'
  spec.add_dependency 'netrc', '= 0.11.0'
  spec.add_dependency 'chronic_duration'
  spec.add_dependency 'thread_safe'
  spec.add_dependency 'rugged'
  spec.add_dependency 'paint'
  spec.add_dependency 'lolcat'
  spec.add_dependency 'config'
  spec.add_dependency 'awesome_print'
  spec.add_dependency 'necromancer', '~> 0.4.0'
  # spec.add_dependency 'notifier'
  # spec.add_dependency 'terminal-notifier'
end
