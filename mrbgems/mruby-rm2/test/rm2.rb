assert('RM2 waveform constants carry the 0xf000 ioctl flag') do
  assert_equal 0xf001, RM2::DU
  assert_equal 0xf002, RM2::GC16
  assert_equal 0xf003, RM2::GL16
  assert_equal 0xf004, RM2::A2
end

assert('RM2 update flag constants') do
  assert_equal 1, RM2::SYNC
  assert_equal 2, RM2::FAST_DRAW
end
