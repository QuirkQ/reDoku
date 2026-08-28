# build_config.rb — mruby build configuration for reDoku.
# Run from the mruby checkout (the container mounts it at /mruby):
#   rake MRUBY_CONFIG=/work/build_config.rb MRUBY_BUILD_DIR=/work/build

# Host build: runs inside the Linux build container; executes mrbtest.
MRuby::Build.new do |conf|
  conf.toolchain :gcc
  conf.gembox 'default'
  conf.gem File.expand_path('mrbgems/mruby-rm2', File.dirname(__FILE__))
  conf.gem File.expand_path('mrbgems/mruby-sqlite3', File.dirname(__FILE__))
  conf.gem File.expand_path('mrbgems/mruby-redoku', File.dirname(__FILE__))
  conf.gem File.expand_path('mrbgems/mruby-bin-redoku', File.dirname(__FILE__))
  conf.enable_debug
  conf.enable_test
  conf.enable_bintest
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

  # Cross builds select no platform implementation by default, which leaves
  # mruby-io/mruby-dir/mruby-socket HAL symbols (mrb_hal_io_*, mrb_hal_dir_*)
  # undefined at link time. The device is ARM Linux, so posix is correct.
  #
  # Which SPELLING is correct depends on which mruby you build against, and
  # this repo can be built against two different ones — see the Makefile's
  # `MRUBY_DIR ?= $(firstword $(wildcard ../mruby) tmp/mruby)`. A developer
  # with a sibling ../mruby checkout builds against that; CI has no sibling,
  # so it clones tmp/mruby at $(MRUBY_REF), currently the 4.0.0 tag. Those
  # are different API generations:
  #
  #   * post-4.0.0 mruby (master) has the ports API — `conf.ports :posix`.
  #   * the 4.0.0 RELEASE has no ports API at all (`grep -r ports
  #     lib/mruby/*.rb` is empty) and instead ships the HAL as core gems,
  #     `hal-posix-io` and friends, one of which each of mruby-io, mruby-dir
  #     and mruby-socket requires.
  #
  # Hard-coding either one breaks the other, and it breaks it at config-parse
  # time with a NoMethodError or a missing-gem abort — before any compilation,
  # so there is no partial build to diagnose from. Feature-detect instead.
  #
  # Naming the HAL explicitly also matters on the 4.0.0 path: left to itself
  # each gem auto-selects from RUBY_PLATFORM, which is the HOST's platform,
  # not the target's — a cross build would be right only by coincidence, and
  # mruby warns you to say it explicitly.
  if conf.respond_to?(:ports)
    conf.ports :posix
  else
    conf.gem core: 'hal-posix-io'
    conf.gem core: 'hal-posix-dir'
    conf.gem core: 'hal-posix-socket'
  end

  conf.gem File.expand_path('mrbgems/mruby-rm2', File.dirname(__FILE__))
  conf.gem File.expand_path('mrbgems/mruby-sqlite3', File.dirname(__FILE__))
  conf.gem File.expand_path('mrbgems/mruby-redoku', File.dirname(__FILE__))
  conf.gem File.expand_path('mrbgems/mruby-bin-redoku', File.dirname(__FILE__))

  conf.build_mrbtest_lib_only
  conf.disable_cxx_exception
end
