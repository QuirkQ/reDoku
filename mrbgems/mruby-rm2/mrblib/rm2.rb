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

  class Display
    # Flush a damage rectangle to the panel. Returns the server's ack
    # (false means we are not the front client and the update was dropped).
    def update(x, y, w, h, waveform: GL16, flags: 0)
      update_raw(x, y, w, h, waveform, flags)
    end
  end
end
