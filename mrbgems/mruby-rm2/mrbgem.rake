MRuby::Gem::Specification.new('mruby-rm2') do |spec|
  spec.license = 'AGPL-3.0-or-later'
  spec.author  = 'Quint Pieters'
  spec.summary = 'reMarkable 2 rm2fb display-server client'

  # mrb_sys_fail raises SystemCallError only when mruby-errno is present;
  # without it the documented error contract silently degrades to RuntimeError.
  spec.add_dependency('mruby-errno', core: 'mruby-errno')

  # Input.resolve_all reads device names out of sysfs.
  spec.add_dependency('mruby-io',  core: 'mruby-io')
  spec.add_dependency('mruby-dir', core: 'mruby-dir')

  # Tests read the fake server's logs and assert raw wire bytes.
  spec.add_test_dependency('mruby-pack', core: 'mruby-pack')

  # One test times RM2::Input.wait, to prove it still paces its timeout when
  # every source has hung up. Declared rather than leaned on: Time reaches
  # this gem's mrbtest state today only as a test dependency of mruby-io.
  spec.add_test_dependency('mruby-time', core: 'mruby-time')
end
