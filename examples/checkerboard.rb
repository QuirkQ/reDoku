# examples/checkerboard.rb — Milestone 0 smoke test payload.
# On the device (rm2fb server running):
#   ./mruby checkerboard.rb [/var/run/rm2fb.sock]
d = RM2::Display.open(*ARGV)
cell = 156 # 1404 / 9
cols = (d.width + cell - 1) / cell
rows = (d.height + cell - 1) / cell
rows.times do |r|
  cols.times do |c|
    d.fill_rect(c * cell, r * cell, cell, cell, (r + c).odd? ? 0 : 255)
  end
end
d.update(0, 0, d.width, d.height, waveform: RM2::GC16, flags: RM2::SYNC)
d.close
puts "checkerboard flushed: #{cols}x#{rows} cells"
