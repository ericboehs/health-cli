module Health
  # What the tool is doing while it waits on the provider.
  #
  # A record walk is two or three requests and Millennium spends about fifteen
  # seconds on each of them, so the honest default — printing nothing until the
  # table is ready — is indistinguishable from a hang. That is worth fixing on a
  # terminal and worth not fixing anywhere else: progress that redraws a line is
  # noise in a log file and corruption in a pipe.
  #
  # So the choice of reporter is made once, from the stream and the flags, and
  # the three implementations share two methods. Only the interactive case
  # changed; `--verbose`, `--quiet` and a redirected stderr behave exactly as
  # they did before this existed.
  module Progress
    def self.for(err, quiet: false, verbose: false)
      return Null.new if quiet
      return Lines.new(err) if verbose

      err.tty? ? Spinner.new(err) : Null.new
    end

    def self.null = Null.new

    # Says nothing: --quiet, and any non-terminal stderr.
    class Null
      def say(_message) = nil

      def finish = nil
    end

    # One line per step, kept for --verbose because that output is meant to be
    # read after the fact — scrolled back through or piped into a file — which
    # a line that overwrites itself cannot be.
    class Lines
      def initialize(err) = @err = err

      def say(message) = @err.puts("health: #{message}")

      def finish = nil
    end

    # One self-erasing line with a running clock.
    #
    # The clock is the point. A spinner alone says "not dead"; the elapsed
    # seconds are what let someone decide whether fifteen seconds on one page is
    # this server being itself or something being wrong. It has to come off a
    # thread, because the wait it is describing is a blocking read inside
    # Net::HTTP and nothing on the main thread runs until that returns.
    class Spinner
      FRAMES = %w[⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏].freeze

      # Fast enough to look continuous, slow enough that a fifteen-second wait
      # costs under two hundred writes.
      INTERVAL = 0.08

      def initialize(err, interval: INTERVAL, clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) })
        @err = err
        @interval = interval
        @clock = clock
        @started = clock.call
        @lock = Mutex.new
        @frame = 0
      end

      def say(message)
        @lock.synchronize { @message = message }
        draw
        @thread ||= Thread.new { loop { sleep(@interval); draw } }
      end

      # Leaves the cursor on a clean line, so whatever prints next — a table, an
      # error, a shell prompt after Ctrl-C — starts where it would have started.
      # Callers put this in an `ensure`.
      def finish
        @thread&.kill
        @thread = nil
        @lock.synchronize do
          @err.print("\r\e[K") if @message
          @message = nil
        end
      end

      private

      # Under the lock because `finish` may run on the main thread while the
      # ticker is mid-draw, and the one thing that must not happen is a frame
      # landing after the line was erased.
      def draw
        @lock.synchronize do
          next if @message.nil?

          @frame += 1
          @err.print("\r\e[K#{FRAMES[@frame % FRAMES.size]} #{@message} · #{elapsed}s")
        end
      end

      def elapsed = (@clock.call - @started).round
    end
  end
end
