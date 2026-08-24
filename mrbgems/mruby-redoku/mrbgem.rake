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

  # Rng.from_clock seeds the generator from Time.now, so that every launch
  # does not deal the same puzzle (Rng's constructor default seed is the
  # literal 1). Time already arrives here transitively through mruby-rm2, so
  # this changes the DECLARATION and not the gembox content — declared anyway
  # because this project has been bitten four times by exactly that gap: a
  # gem's mrbtest state holds only its declared dependencies, while the
  # shipped binary links the whole default gembox, so an undeclared gem's
  # method passes on the device and raises NoMethodError under `make test`.
  spec.add_dependency('mruby-time', core: 'mruby-time')
end
