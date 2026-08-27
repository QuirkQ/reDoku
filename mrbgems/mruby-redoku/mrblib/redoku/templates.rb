module Redoku
  # Bootstrap digit templates, authored by hand rather than recorded, so the
  # recognizer is testable on the host from the first commit (spec §5: the
  # chicken-and-egg is that --record needs a recognizer and a recognizer
  # needs templates). Task 11 replaces these with the owner's own recorded
  # clouds, which become both the shipped set and the corpus.
  #
  # Each entry is [digit, subpaths] in a 100x100 box, origin top-left. Two
  # or three variants per digit cover the ways a hand actually draws it —
  # a 7 with and without a crossbar, a 4 open and closed, a 1 with and
  # without a serif — because hands disagree about stroke COUNT, and the
  # variants absorb that spread. (The borrowed $P invariance to stroke
  # ORDER/DIRECTION is gone: stage 1's start/end-point features do key on
  # direction, which PLAN.md §10 records as an accepted trade re-measured
  # in Task 11 — before any retuning, this warning applies there too.)
  module Templates
    AUTHORED = [
      [1, [[[50, 8], [50, 92]]]],
      [1, [[[34, 24], [50, 8], [50, 92]]]],
      [1, [[[34, 24], [50, 8], [50, 92]], [[30, 92], [70, 92]]]],

      [2, [[[18, 26], [34, 10], [62, 10], [76, 26], [70, 46],
            [20, 90], [80, 90]]]],
      [2, [[[20, 28], [50, 8], [78, 28], [66, 52], [18, 92], [82, 92]]]],

      [3, [[[20, 12], [70, 12], [44, 46], [74, 60], [64, 90], [22, 88]]]],
      [3, [[[22, 14], [66, 10], [46, 46], [76, 62], [60, 92], [20, 86]]]],

      [4, [[[64, 8], [18, 62], [86, 62]], [[64, 8], [64, 92]]]],
      [4, [[[62, 10], [20, 64], [84, 64]], [[62, 34], [62, 92]]]],
      [4, [[[26, 8], [26, 52], [80, 52], [66, 8], [66, 92]]]],

      [5, [[[80, 10], [26, 10], [24, 44], [58, 42], [78, 62],
            [62, 90], [22, 86]]]],
      [5, [[[78, 12], [28, 12], [26, 46], [60, 44], [76, 66], [58, 92],
            [20, 84]]]],

      [6, [[[70, 10], [34, 40], [26, 70], [46, 90], [72, 78],
            [66, 54], [34, 52]]]],
      [6, [[[72, 12], [36, 44], [28, 72], [50, 92], [74, 76], [64, 52],
            [32, 54]]]],

      [7, [[[16, 12], [84, 12], [40, 92]]]],
      [7, [[[16, 12], [84, 12], [40, 92]], [[28, 52], [64, 52]]]],
      [7, [[[18, 10], [82, 14], [44, 90]]]],

      [8, [[[54, 10], [30, 26], [54, 44], [76, 62], [54, 90],
            [28, 68], [54, 44], [72, 26], [54, 10]]]],
      [8, [[[52, 12], [28, 28], [52, 46], [74, 64], [50, 90], [26, 66],
            [52, 46], [70, 28], [52, 12]]]],

      [9, [[[70, 40], [40, 48], [30, 26], [54, 10], [70, 28],
            [70, 40], [58, 90]]]],
      [9, [[[72, 42], [42, 50], [32, 26], [56, 10], [72, 30], [70, 44],
            [54, 92]]]]
    ].freeze
  end
end
