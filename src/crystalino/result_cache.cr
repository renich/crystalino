require "./requires"

class Crystalino::ResultCache
  # A monotonic timestamp used to store the invalidation date.
  @@reference_clock = Time.instant

  # A cache of compiler results with invalidation time, indexed by file name.
  @cache : Hash(String, {Crystal::Compiler::Result?, Time::Span?}) = Hash(String, {Crystal::Compiler::Result?, Time::Span?}).new
  @mutex : Mutex = Mutex.new

  # Remove the result, store the timestamp.
  def invalidate(entry : String)
    @mutex.synchronize do
      @cache[entry] = {nil, monotonic_now}
    end
  end

  # True if the entry (filename) has already been used as a compilation target.
  def exists?(entry : String) : Bool
    @mutex.synchronize { @cache.has_key?(entry) }
  end

  # True if the cache has been invalidated *since* the *since* time argument,
  # or if the entry is invalidated if *since* is not provided.
  def invalidated?(entry : String, *, since : Time::Span? = nil) : Bool
    @mutex.synchronize do
      entry_tuple = @cache[entry]?
      return false unless entry_tuple

      invalidation_time = entry_tuple[1]
      if since
        !invalidation_time.nil? && invalidation_time > since
      else
        !invalidation_time.nil?
      end
    end
  end

  # Get a cache value.
  def get(entry : String) : Crystal::Compiler::Result?
    @mutex.synchronize { @cache[entry]?.try &.[0] }
  end

  # Store a compiler result by target name.
  #
  # If *unless_invalidated_since* is provided, it will not store the result if the previous result has been
  # invalidated since the provided timestamp.
  def set(entry : String, result : Crystal::Compiler::Result?, *, unless_invalidated_since : Time::Span? = nil)
    @mutex.synchronize do
      if since = unless_invalidated_since
        entry_tuple = @cache[entry]?
        if entry_tuple
          inv_time = entry_tuple[1]
          return if !inv_time.nil? && inv_time > since
        end
      end
      @cache[entry] = {result, nil}
    end
  end

  # Return the current monotonic time.
  def monotonic_now
    Time.instant - @@reference_clock
  end
end
