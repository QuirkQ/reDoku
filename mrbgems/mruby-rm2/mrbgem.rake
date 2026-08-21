MRuby::Gem::Specification.new('mruby-rm2') do |spec|
  spec.license = 'MIT'
  spec.author  = 'Quint Pieters'
  spec.summary = 'reMarkable 2 rm2fb display-server client'

  # mrb_sys_fail raises SystemCallError only when mruby-errno is present;
  # without it the documented error contract silently degrades to RuntimeError.
  spec.add_dependency('mruby-errno', core: 'mruby-errno')

  # Tests read the fake server's update log and assert raw wire bytes.
  spec.add_test_dependency('mruby-io',    core: 'mruby-io')
  spec.add_test_dependency('mruby-pack',  core: 'mruby-pack')
end
