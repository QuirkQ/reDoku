module Redoku
  module Sudoku
    # Difficulty, defined as "what would it take to solve this by hand".
    #
    # PLAN.md §7 states all three tiers as a CONJUNCTION of a technique and a
    # clue count — easy is "singles only, >= 36 clues", medium "requires
    # pairs/pointing, 28-35", hard "the technique solver stalls, 24-30". Both
    # halves are used here, and the reason is measurement rather than
    # fidelity for its own sake.
    #
    # An earlier version rated on the technique alone: singles -> easy, any
    # elimination -> medium, a stall -> hard. Benchmarked against the real
    # generator, that collapsed two tiers into one, because most boards in
    # the 28-35 clue band turn out to be singles-only — four attempts in
    # five. So a :medium request produced :easy over and over, burned its
    # whole twelve-attempt budget, and took 1.9 s to fail. The
    # needs-an-elimination band is THIN, not wide, which is the opposite of
    # what I had assumed when planning it.
    #
    # Bringing the clue count in fixes that: a board needing nothing but
    # singles is only easy if it is also generously clued. The same board
    # with 30 clues is more work even though every step is simple, which is
    # both true to how it plays and what §7 actually says.
    class Rater
      TIERS = [:easy, :medium, :hard].freeze

      # §7's easy floor. Below it, singles-only is not enough to be easy.
      EASY_MIN_CLUES = 36

      SINGLES = [:naked_single, :hidden_single].freeze

      # nil means the board arrived finished, which needed no technique at
      # all and so counts as singles-only.
      def self.singles_only?(hardest)
        hardest.nil? || SINGLES.include?(hardest)
      end

      # The tier of a board the technique solver DID finish. `:hard` is
      # deliberately unreachable from here: it is not a technique but the
      # absence of one, and only `rate` knows whether the solver stalled.
      def self.tier_for(hardest, clues)
        return :easy if singles_only?(hardest) && clues >= EASY_MIN_CLUES
        :medium
      end

      def self.clue_count(values)
        n = 0
        values.each { |d| n += 1 if d != 0 }
        n
      end

      def self.rate(values)
        result = Techniques.solve(values)
        return :hard unless result[:solved]
        tier_for(result[:hardest], clue_count(values))
      end
    end
  end
end
