# coding: utf-8
lib = File.expand_path('../lib', __FILE__)
$LOAD_PATH.unshift(lib) unless $LOAD_PATH.include?(lib)
require 'hu/version'

Gem::Specification.new do |spec|
  spec.name          = "hu"
  spec.version       = Hu::VERSION
  spec.authors       = ["moe"]
  spec.email         = ["moe@busyloop.net"]
  spec.summary       = %q{Heroku Utility.}
  spec.description   = %q{Heroku Utility.}
  spec.homepage      = "https://github.com/busyloop/hu"
  spec.license       = "MIT"

  spec.files         = `git ls-files`.split($/)
  spec.executables   = spec.files.grep(%r{^bin/}) { |f| File.basename(f) }
  spec.test_files    = spec.files.grep(%r{^(test|spec|features)/})
  spec.require_paths = ["lib"]

  spec.add_development_dependency "bundler", "~> 1.5"
  spec.add_development_dependency "rake"

  spec.add_dependency "optix"
  spec.add_dependency "platform-api"
  spec.add_dependency "powerbar"
end
