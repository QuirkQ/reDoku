# build_config.rb — mruby build configuration for reDoku.
# Run from the mruby checkout (the container mounts it at /mruby):
#   rake MRUBY_CONFIG=/work/build_config.rb MRUBY_BUILD_DIR=/work/build

# Host build: runs inside the Linux build container; executes mrbtest.
MRuby::Build.new do |conf|
  conf.toolchain :gcc
  conf.gembox 'default'
  conf.enable_debug
  conf.enable_test
end
