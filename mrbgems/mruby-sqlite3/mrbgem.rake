MRuby::Gem::Specification.new('mruby-sqlite3') do |spec|
  spec.license = 'MIT'
  spec.author  = 'Quint Pieters'
  spec.summary = 'SQLite3 binding for reDoku saves (vendored amalgamation + mattn binding)'

  # The SQLite amalgamation is vendored in src/ and compiled into the binary;
  # there is no external libsqlite3 to link against.
  #
  # Slimming flags are tuned here only (gem-local), never project-wide: the
  # amalgamation is third-party code and must not force relaxations elsewhere.
  spec.cc.flags << %w[
    -DSQLITE_THREADSAFE=0
    -DSQLITE_OMIT_LOAD_EXTENSION
    -DSQLITE_DEFAULT_MEMSTATUS=0
    -DSQLITE_OMIT_DEPRECATED
    -DSQLITE_OMIT_PROGRESS_CALLBACK
    -DSQLITE_MAX_EXPR_DEPTH=0
  ]

  # Tests delete and reopen DB files under /tmp.
  spec.add_test_dependency('mruby-io', core: 'mruby-io')
end
