module Redoku
  # `redoku --record` walks the player through writing each digit a few
  # times and saves the clouds, so the recognizer can be tuned to ONE hand
  # rather than to an average of many (PLAN.md §6). Kept as a plain state
  # machine with no display and no input in it, so the whole walk is
  # host-testable: main.rb owns the loop that feeds it strokes and paints
  # the prompt.
  class Recorder
    DIGITS  = 9
    DEFAULT_ROUNDS = 4
    TARGET  = '/home/root/redoku/templates.local'

    attr_reader :samples

    def initialize(rounds: DEFAULT_ROUNDS)
      @rounds = rounds
      @samples = []
    end

    # The digit being asked for right now, or nil when the walk is over.
    # Round-major: 1..9, then 1..9 again — not nine 1s in a row, because a
    # hand drilling the same glyph nine times drifts into a stylised
    # version of it that the player never writes in play.
    def wanted
      return nil if done?
      (@samples.size % DIGITS) + 1
    end

    def done?
      @samples.size >= @rounds * DIGITS
    end

    def accept(subpaths)
      return self if done?
      @samples << [wanted, subpaths]
      self
    end

    # One line per sample: digit, TAB, then the shared points codec. Text
    # and not binary for the reason M3a records at Store.encode_pts — the
    # SQLite binding reads TEXT with mrb_str_new_cstr, which truncates at
    # the first NUL, so this codebase has exactly one points encoding and
    # it is this one.
    def to_text
      out = ''
      @samples.each do |digit, subpaths|
        enc = Store.encode_pts(subpaths)
        next unless enc
        out = out + digit.to_s + "\t" + enc + "\n"
      end
      out
    end

    # A corrupt line is skipped, never fatal: this file is written on a
    # device that can lose power mid-write, and a half-written last line
    # must not cost the player the 35 good samples above it.
    def self.parse(text)
      out = []
      text.split("\n").each do |line|
        parts = line.split("\t")
        next unless parts.size == 2
        d = parts[0]
        next unless d.size == 1 && d >= '1' && d <= '9'
        subpaths = Store.decode_pts(parts[1])
        next unless subpaths
        out << [d.to_i, subpaths]
      end
      out
    end
  end
end
