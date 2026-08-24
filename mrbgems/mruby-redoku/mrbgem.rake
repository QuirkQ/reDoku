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
  # literal 1).
  #
  # Time reaches both of this project's builds from `conf.gembox 'default'` in
  # build_config.rb, and NOT from mruby-rm2: that gem declares mruby-time with
  # add_test_dependency, which furnishes its own mrbtest state and does not
  # propagate to anything that depends on it. So this line adds nothing to the
  # shipped binary — and it is exactly what makes THIS gem's mrbtest state
  # hold Time on its own account rather than by grace of a gembox it does not
  # control. A gem's mrbtest state holds only its declared dependencies while
  # the shipped binary links the whole gembox, so an undeclared gem's method
  # passes on the device and raises NoMethodError under `make test`; this
  # project has been bitten four times by that gap, and an explicit
  # declaration is the documented remedy. Do not remove it on the grounds
  # that something else supplies Time today.
  spec.add_dependency('mruby-time', core: 'mruby-time')
end
