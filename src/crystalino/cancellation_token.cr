module Crystalino
  # Thread-safe cancellation token used to abort long-running
  # compiler passes when superseded by newer edits or requests.
  class CancellationToken
    getter? cancelled : Atomic(Bool)

    def initialize
      @cancelled = Atomic(Bool).new(false)
    end

    # Signals cancellation.
    def cancel : Nil
      @cancelled.set(true)
    end

    # Returns true if cancellation has been requested.
    def cancelled? : Bool
      @cancelled.get
    end
  end

  # Exception raised when a compilation pass is cancelled mid-flight.
  class CompilationCancelledException < Exception
    getter stage : String

    def initialize(@stage : String = "unknown")
      super("Compilation cancelled at stage: #{@stage}")
    end
  end
end
