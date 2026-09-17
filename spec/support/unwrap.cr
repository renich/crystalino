class Object
  # Explicitly unwrap for testing instead of using .not_nil! to satisfy Ameba
  def unwrap!(file = __FILE__, line = __LINE__)
    self || raise "Expected unwrapped value not to be nil at #{file}:#{line}"
  end
end

struct Nil
  def unwrap!(file = __FILE__, line = __LINE__)
    raise "Expected unwrapped value not to be nil at #{file}:#{line}"
  end
end
