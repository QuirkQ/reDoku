MRuby::Gem::Specification.new('mruby-bin-redoku') do |spec|
  spec.license = 'MIT'
  spec.author  = 'Quint Pieters'
  spec.summary = 'redoku executable'
  spec.bins    = %w[redoku]

  # The game itself; mruby-rm2 arrives through it.
  spec.add_dependency('mruby-redoku', path: File.expand_path('../mruby-redoku', File.dirname(__FILE__)))
end
