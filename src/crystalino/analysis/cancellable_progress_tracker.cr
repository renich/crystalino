require "compiler/crystal/progress_tracker"
require "../cancellation_token"

module Crystalino::Analysis
  # Custom progress tracker that intercepts compilation stages and aborts
  # immediately if the compilation has been superseded or cancelled.
  class CancellableProgressTracker < Crystal::ProgressTracker
    getter cancellation_token : CancellationToken?

    def initialize(@cancellation_token : CancellationToken? = nil)
      super()
    end

    def stage(name, &)
      check_cancelled(name)
      retval = super(name) { yield }
      check_cancelled("#{name} (post-stage)")
      retval
    end

    private def check_cancelled(stage_name : String) : Nil
      token = @cancellation_token
      return unless token
      return unless token.cancelled?

      raise CompilationCancelledException.new(stage_name)
    end
  end
end
