MRuby::Gem::Specification.new('mruby-redoku') do |spec|
  spec.license = 'AGPL-3.0-or-later'
  spec.author  = 'Quint Pieters'
  spec.summary = 'reDoku game logic: layout, rendering, input handling'

  # Drawing and input go through the rm2fb client shim.
  spec.add_dependency('mruby-rm2', path: File.expand_path('../mruby-rm2', File.dirname(__FILE__)))

  # Store (M3a) is Ruby over the SQLite3 binding, vendored next door. THE
  # DEPENDENCY TRAP AGAIN, in its original form: without this line the gem's
  # own mrbtest state holds no SQLite3 constant, so every Store test dies with
  # NameError under `make test` while the shipped binary — which links the
  # whole tree via build_config.rb — works on the device.
  spec.add_dependency('mruby-sqlite3', path: File.expand_path('../mruby-sqlite3', File.dirname(__FILE__)))

  # Store walks the filesystem itself: make_parent_dirs uses Dir.mkdir /
  # Dir.exist? (mruby-dir), and open/quarantine use File.exist?, File.rename
  # and File.dirname (mruby-io). Both ship in the default gembox; these
  # declarations exist so THIS gem's mrbtest state holds them on its own
  # account rather than by grace of a gembox it does not control.
  spec.add_dependency('mruby-io',  core: 'mruby-io')
  spec.add_dependency('mruby-dir', core: 'mruby-dir')

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

  # This project spent two milestones treating a long list of Ruby methods
  # (Array#uniq, Hash#fetch, format, Set, Struct, Object#send, and more) as
  # unavailable in mruby, and was bitten four times by using one anyway: it
  # PASSES on device and raises NoMethodError under `make test`. Reading
  # build_config.rb shows both build targets call `conf.gembox 'default'`,
  # and mrbgems/default.gembox pulls in stdlib, stdlib-ext, stdlib-io, math
  # and metaprog — which is exactly where all of the methods above live. The
  # shipped binary already links every gem below; the list was never a
  # description of mruby's limits, it was a description of this gem's
  # undeclared dependencies. As with mruby-time above, a gem's mrbtest state
  # holds only what it declares, so these declarations change nothing about
  # the device binary and exist solely to make `make test` see what already
  # ships.
  spec.add_dependency('mruby-array-ext',   core: 'mruby-array-ext')
  spec.add_dependency('mruby-enum-ext',    core: 'mruby-enum-ext')
  spec.add_dependency('mruby-hash-ext',    core: 'mruby-hash-ext')
  spec.add_dependency('mruby-numeric-ext', core: 'mruby-numeric-ext')
  spec.add_dependency('mruby-compar-ext',  core: 'mruby-compar-ext')
  spec.add_dependency('mruby-sprintf',     core: 'mruby-sprintf')
  spec.add_dependency('mruby-random',      core: 'mruby-random')
  spec.add_dependency('mruby-catch',       core: 'mruby-catch')
  spec.add_dependency('mruby-set',         core: 'mruby-set')
  spec.add_dependency('mruby-struct',      core: 'mruby-struct')
  # Object#send and #instance_variable_set are mruby-metaprog (src/metaprog.c),
  # not core: core only defines __send__ (src/class.c), and mruby-metaprog is
  # what the default gembox's `metaprog.gembox` pulls in for the plain names.
  spec.add_dependency('mruby-metaprog',    core: 'mruby-metaprog')
end
