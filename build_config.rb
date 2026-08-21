# build_config.rb — mruby build configuration for reDoku.
# Run from the mruby checkout (the container mounts it at /mruby):
#   rake MRUBY_CONFIG=/work/build_config.rb MRUBY_BUILD_DIR=/work/build

# Host build: runs inside the Linux build container; executes mrbtest.
MRuby::Build.new do |conf|
  conf.toolchain :gcc
  conf.gembox 'default'
  conf.gem File.expand_path('mrbgems/mruby-rm2', File.dirname(__FILE__))
  conf.gem File.expand_path('mrbgems/mruby-redoku', File.dirname(__FILE__))
  conf.enable_debug
  conf.enable_test
end

# Device build: armv7hf cross-compile for the reMarkable 2 (firmware >= 3.18,
# glibc-compatible per PLAN.md §5). Produces bin/mruby for on-device use.
MRuby::CrossBuild.new('rm2') do |conf|
  conf.toolchain :gcc

  tc = '/opt/x-tools/arm-remarkable-linux-gnueabihf/bin/arm-remarkable-linux-gnueabihf'
  conf.cc do |cc|
    cc.command = "#{tc}-gcc"
    cc.flags << %w[-march=armv7-a -mfpu=neon -mfloat-abi=hard -O2]
  end
  conf.linker do |linker|
    linker.command = "#{tc}-gcc"
  end
  conf.archiver do |archiver|
    archiver.command = "#{tc}-ar"
  end

  conf.gembox 'default'

  # Cross builds select NO platform port by default (lib/mruby/build.rb
  # effective_ports returns [] for MRuby::CrossBuild), which leaves
  # mruby-io/mruby-dir HAL symbols (mrb_hal_io_*, mrb_hal_dir_*) undefined
  # at link time. The device is ARM Linux, so the posix port is correct.
  conf.ports :posix

  conf.gem File.expand_path('mrbgems/mruby-rm2', File.dirname(__FILE__))
  conf.gem File.expand_path('mrbgems/mruby-redoku', File.dirname(__FILE__))

  conf.build_mrbtest_lib_only
  conf.disable_cxx_exception
end
