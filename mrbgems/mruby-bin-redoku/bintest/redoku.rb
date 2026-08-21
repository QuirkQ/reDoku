require 'open3'

# cmd_bin comes from mruby's test/bintest.rb: it resolves the built binary
# in the target's BUILD_DIR and copes with EMULATOR / .exe suffixes.
REDOKU = cmd_bin('redoku')

assert('redoku --help explains itself and exits 0') do
  out, _err, status = Open3.capture3(REDOKU, '--help')
  assert_true status.success?
  assert_include out, 'redoku'
  assert_include out, '--clients'
end

assert('redoku fails clearly when no display server is listening') do
  # No rm2fb server exists in the build container, so the default socket
  # path is absent and this exercises the real failure path.
  _out, err, status = Open3.capture3(REDOKU)
  assert_false status.success?
  assert_include err, 'redoku:'
end

assert('redoku rejects an unknown option instead of guessing') do
  _out, err, status = Open3.capture3(REDOKU, '--nonsense')
  assert_false status.success?
  assert_include err, '--nonsense'
end
