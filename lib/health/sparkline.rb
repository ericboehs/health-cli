module Health
  # A one-line chart of a series of numbers, for `health labs --history --trend`.
  #
  # Deliberately just the shape of the series. It is scaled to its own minimum
  # and maximum, not to the reference range, so a flat-but-abnormal analyte and
  # a flat-and-normal one draw identically — the sparkline answers "which way is
  # this going", and the table above it answers "is this a problem".
  module Sparkline
    LEVELS = %w[▁ ▂ ▃ ▄ ▅ ▆ ▇ █].freeze

    module_function

    # `values` oldest first. Returns nil rather than a misleading picture when
    # there are fewer than two points: one block on its own conveys a trend that
    # was never measured.
    def render(values)
      numbers = values.compact.map(&:to_f)
      return nil if numbers.size < 2

      low, high = numbers.minmax
      span = high - low

      numbers.map { |n|
        # A series that never moves sits in the middle rather than the floor.
        # Scaled against its own range it would otherwise be all ▁, which reads
        # as "bottomed out" instead of "unchanged".
        index = span.zero? ? (LEVELS.size / 2) : ((n - low) / span * (LEVELS.size - 1)).round
        LEVELS[index]
      }.join
    end

    # The numbers under the picture: where the series started, where it ended,
    # and by how much it moved.
    def summarize(values)
      numbers = values.compact.map(&:to_f)
      return nil if numbers.size < 2

      first = numbers.first
      last = numbers.last
      change = last - first
      low, high = numbers.minmax

      {
        first: first, last: last, change: change, low: low, high: high,
        # Undefined rather than infinite when the series starts at zero, which
        # a lab value legitimately can.
        percent: first.zero? ? nil : (change / first * 100),
        direction: direction_of(change),
        count: numbers.size
      }
    end

    def direction_of(change)
      return "flat" if change.zero?

      change.positive? ? "rising" : "falling"
    end
  end
end
