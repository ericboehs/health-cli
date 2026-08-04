module Health
  # Column-aligned plain text, shared by the FHIR record commands.
  #
  # Widths are measured rather than fixed. A drug name runs from "Aspirin" to
  # "Albuterol (Eqv-ProAir HFA) 90 mcg/inh inhalation aerosol", and a fixed
  # width either wastes most of the screen or lets one long name shove every
  # column after it out of alignment.
  #
  # `health labs` keeps its own renderer. Its output is not a table of the same
  # kind — it groups into panels with a heading per panel and drops a column in
  # history mode — and folding those two shapes into one implementation would
  # cost more in special cases than it saves in lines.
  class Table
    Column = Data.define(:label, :align, :max) do
      def right? = align == :right
    end

    # A cell that is absent, rather than empty. The distinction matters in a
    # medical record: an empty cell under "Refills" reads as none left, when
    # what it means is that the prescription never said.
    BLANK = "—".freeze

    ELLIPSIS = "…".freeze

    # `columns` is [label, options] pairs — :align (:left, the default, or
    # :right) and :max, a width past which a cell is truncated.
    def initialize(*columns)
      @columns = columns.map do |label, opts|
        opts ||= {}
        Column.new(label: label.to_s, align: opts[:align] || :left, max: opts[:max])
      end
    end

    # Returns the rendered lines. Returns them rather than printing them so a
    # caller can decide about pagination, and so tests can assert on the shape
    # without capturing a stream.
    def render(rows, header: true)
      cells = rows.map { |row| @columns.each_with_index.map { |c, i| cell(row[i], c) } }
      widths = widths_for(cells, header: header)

      lines = []
      if header
        lines << line(@columns.map(&:label), widths)
        lines << line(widths.map { |w| "-" * w }, widths)
      end
      lines.concat(cells.map { |row| line(row, widths) })
    end

    private

    def cell(value, column)
      text = value.to_s.strip
      return BLANK if text.empty?
      return text unless column.max && text.length > column.max

      # Truncate to the *column's* width including the marker, so a truncated
      # cell never widens the column past what was asked for.
      text[0, column.max - 1] + ELLIPSIS
    end

    def widths_for(cells, header:)
      @columns.each_with_index.map do |column, i|
        candidates = cells.map { |row| row[i].to_s.length }
        candidates << column.label.length if header
        candidates.max || 0
      end
    end

    # Trailing whitespace is stripped so a copied line doesn't carry the
    # padding of the widest row after it.
    def line(cells, widths)
      cells.each_with_index.map { |text, i|
        @columns[i].right? ? text.to_s.rjust(widths[i]) : text.to_s.ljust(widths[i])
      }.join("  ").rstrip
    end
  end
end
