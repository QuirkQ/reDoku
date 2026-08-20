MRuby::Gem::Specification.new('mruby-rm2') do |spec|
  spec.license = 'MIT'
  spec.author  = 'Quint Pieters'
  spec.summary = 'reMarkable 2 rm2fb display-server client'

  # Tests read the fake server's update log and assert raw wire bytes.
  spec.add_test_dependency('mruby-io',    core: 'mruby-io')
  spec.add_test_dependency('mruby-pack',  core: 'mruby-pack')
  spec.add_test_dependency('mruby-errno', core: 'mruby-errno')
end
