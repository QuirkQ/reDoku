MRuby::Gem::Specification.new('mruby-redoku') do |spec|
  spec.license = 'MIT'
  spec.author  = 'Quint Pieters'
  spec.summary = 'reDoku game logic: layout, rendering, input handling'

  # Drawing and input go through the rm2fb client shim.
  spec.add_dependency('mruby-rm2', path: File.expand_path('../mruby-rm2', File.dirname(__FILE__)))

  # Font.draw walks label text with String#each_char, which is string-ext,
  # not core. A gem's mrbtest state holds only its declared dependencies, so
  # an undeclared gem raises NoMethodError under `make test` even though the
  # shipped binary links the whole default gembox.
  spec.add_dependency('mruby-string-ext', core: 'mruby-string-ext')
end
