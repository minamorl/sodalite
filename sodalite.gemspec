# frozen_string_literal: true

require_relative 'lib/sodalite/version'

Gem::Specification.new do |spec|
  spec.name = 'sodalite'
  spec.version = Sodalite::VERSION
  spec.summary = 'A web framework where the request is a value and the world is a parameter'
  spec.description = 'Puma for transport, zeolite for both boundaries, berylx for the workflow, and ' \
                     'darkcore for the effects. A route declares the shape it admits and the shape it ' \
                     'publishes; nothing untyped gets in, and nothing untyped gets out. Swapping the ' \
                     'handler map runs the same service against a real database or against fixed values.'
  spec.authors = ['minamorl']
  spec.email = ['minamorl@users.noreply.github.com']
  spec.license = 'MIT'
  spec.homepage = 'https://github.com/minamorl/sodalite'

  spec.required_ruby_version = '>= 3.2'
  spec.metadata['rubygems_mfa_required'] = 'true'
  spec.metadata['source_code_uri'] = spec.homepage

  spec.files = Dir[
    'lib/**/*.rb',
    'docs/**/*.md',
    'README.md',
    'LICENSE',
    'AGENTS.md'
  ]
  spec.require_paths = ['lib']

  # The axis. zeolite is the sieve at both boundaries, berylx composes the named
  # tasks a route is made of, darkcore is the substrate they run on, and puma is
  # the server whose threaded model this framework's concurrency story assumes.
  spec.add_dependency 'berylx'
  spec.add_dependency 'darkcore'
  spec.add_dependency 'puma', '>= 6.0'
  spec.add_dependency 'rack', '~> 3.0'
  spec.add_dependency 'zeolite'
end
