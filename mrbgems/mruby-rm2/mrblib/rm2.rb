module RM2
  # UpdateParams.waveform on the wire = Linux WAVEFORM_MODE_* constant with
  # the 0xf000 "this is an ioctl constant" flag set; the server translates
  # to its internal LUT (PLAN.md §3).
  WAVEFORM_FLAG = 0xf000
  DU   = 1 | WAVEFORM_FLAG
  GC16 = 2 | WAVEFORM_FLAG
  GL16 = 3 | WAVEFORM_FLAG
  A2   = 4 | WAVEFORM_FLAG

  # UpdateParams.flags bits.
  SYNC      = 1
  FAST_DRAW = 2
end
