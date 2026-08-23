module Redoku
  module Sudoku
    # Difficulty, defined as "what would it take to solve this by hand".
    #
    # PLAN.md §7 ties the tier to the hardest technique needed and to the
    # clue count. The technique is the load-bearing half and the clue count
    # is only a sanity band, because clue count alone is a poor predictor: a
    # 30-clue board can be trivial and a 36-clue board can need pointing
    # pairs. So the technique decides here, and the Generator is what steers
    # the clue count, by choosing when to stop digging.
    class Rater
      TIERS = [:easy, :medium, :hard].freeze

      # Solvable with singles alone -> easy. Needs an elimination rule ->
      # medium. `hard` is not in this mapping on purpose: it is not a
      # technique but the ABSENCE of one, and only `rate` can see that,
      # because only `rate` knows whether the solver finished.
      def self.tier_for(hardest)
        return :easy if hardest.nil?
        return :easy if hardest == :naked_single || hardest == :hidden_single
        :medium
      end

      def self.rate(values)
        result = Techniques.solve(values)
        return :hard unless result[:solved]
        tier_for(result[:hardest])
      end
    end
  end
end
