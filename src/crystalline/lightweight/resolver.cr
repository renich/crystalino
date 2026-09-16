require "./inference"
require "./type_utils"
require "./query"
require "../position_utils"

module Crystalline::Lightweight
  module Resolver
    extend self

    SAFE_TRY_SEGMENT = "__lightweight_try__"
    INDEX_SEGMENT    = "__lightweight_index__"
    RANGE_SEGMENT    = "__lightweight_range__"
    CAST_SEGMENT     = "__lightweight_cast__"

    def receiver_types(source : String, line_number : Int32, analysis_column : Int32, receiver : String, query : Query) : {Array(String), Bool}
      segments = split_receiver_segments(receiver)
      return {[] of String, false} if segments.empty?

      type_names, class_method = root_receiver_types(source, line_number, analysis_column, segments.shift, query)
      return {[] of String, class_method} if type_names.empty?

      resolve_segment_chain(segments, type_names, class_method, query)
    end

    private def split_receiver_segments(receiver : String) : Array(String)
      segments = [] of String
      if receiver.starts_with?('"')
        start = 0
        in_quote = false
        receiver.each_char_with_index do |char, index|
          if char == '"'
            in_quote = !in_quote
          elsif char == '.' && !in_quote
            segments << receiver[start...index]
            start = index + 1
          end
        end
        tail = receiver[start..]
        segments << tail unless tail.empty?
      else
        segments = receiver.split('.').reject(&.empty?)
      end
      segments
    end

    private def resolve_segment_chain(segments : Array(String), type_names : Array(String), class_method : Bool, query : Query) : {Array(String), Bool}
      index = 0
      while index < segments.size
        segment = segments[index]
        if segment == SAFE_TRY_SEGMENT
          safe_method = segments[index + 1]?
          unless safe_method
            safe_receiver_types = type_names.reject(&.==("Nil")).uniq!
            return {safe_receiver_types, false}
          end

          safe_method = "[]" if safe_method == INDEX_SEGMENT
          safe_method = "[]?" if safe_method == "#{INDEX_SEGMENT}?"
          type_names, class_method = safe_chained_call_types(type_names, class_method, safe_method, query)
          return {[] of String, class_method} if type_names.empty?
          index += 2
        else
          type_names, class_method, should_return = resolve_single_segment(segment, type_names, class_method, query)
          return {[] of String, class_method} if should_return
          index += 1
        end
      end
      {type_names, class_method}
    end

    private def resolve_single_segment(segment : String, type_names : Array(String), class_method : Bool, query : Query) : {Array(String), Bool, Bool}
      segment = "[]" if segment == INDEX_SEGMENT
      segment = "[]?" if segment == "#{INDEX_SEGMENT}?"
      if segment == RANGE_SEGMENT
        type_names = type_names.reject(&.==("Nil")).uniq!
        class_method = false
      elsif segment == "#{RANGE_SEGMENT}?"
        type_names = (type_names.reject(&.==("Nil")).uniq! + ["Nil"]).uniq
        class_method = false
      elsif segment.in?("as", "as?")
      elsif segment.starts_with?(CAST_SEGMENT)
        target = segment[CAST_SEGMENT.size + 1..]?
        if target
          target = target.rchop(')')
          type_names = [target]
          class_method = false
        else
          return {[] of String, class_method, true}
        end
      else
        segment = segment.split('(').first? || segment
        type_names, class_method = chained_call_types(type_names, class_method, segment, query)
        return {[] of String, class_method, true} if type_names.empty?
      end
      {type_names, class_method, false}
    end

    def receiver_from_prefix(prefix : String) : String
      normalized_prefix = normalize_receiver_prefix(prefix).rstrip('.').rstrip

      start = scan_receiver_start(normalized_prefix, normalized_prefix.size)
      start = extend_back_quoted_string(normalized_prefix, start)
      normalized_prefix, start = extend_back_block_tail(normalized_prefix, start)
      start = extend_back_cast_segment(normalized_prefix, start)

      receiver = normalized_prefix[start..]? || ""
      strip_range_operator(receiver)
    end

    private def scan_receiver_start(prefix : String, start : Int32) : Int32
      while start > 0 && receiver_expression_char?(prefix[start - 1])
        start -= 1
      end
      start
    end

    private def extend_back_quoted_string(normalized_prefix : String, start : Int32) : Int32
      if start > 0 && normalized_prefix[start - 1] == '"'
        if open_quote = normalized_prefix.rindex('"', start - 2)
          return open_quote
        end
      end
      start
    end

    private def extend_back_block_tail(normalized_prefix : String, start : Int32) : {String, Int32}
      receiver = normalized_prefix[start..]? || ""
      return {normalized_prefix, start} unless receiver.size >= 3 && receiver.starts_with?("end") && (receiver.size == 3 || receiver[3]? == '.')

      do_index = find_do_block_start(normalized_prefix.chars, start - 1)
      if do_index
        suffix = normalized_prefix[start + 3..]? || ""
        new_prefix = normalized_prefix[0, do_index].rstrip + suffix
        new_start = scan_receiver_start(new_prefix, new_prefix.size)
        return {new_prefix, new_start}
      end
      {normalized_prefix, start}
    end

    private def find_do_block_start(chars : Array(Char), index : Int32) : Int32?
      depth = 1
      do_index = nil
      else_seen = false
      while index >= 0 && depth > 0
        if token_char?(chars[index])
          token, token_start = build_backward_token(chars, index)
          if token == "end"
            depth += 1
            else_seen = false
          elsif token == "do"
            depth -= 1
            do_index = token_start if depth == 0
          elsif token.in?("else", "elsif") && !else_seen
            depth -= 1
            else_seen = true
          end
          index = token_start - 1
        else
          index -= 1
        end
      end
      do_index
    end

    private def build_backward_token(chars : Array(Char), index : Int32) : {String, Int32}
      token_end = index + 1
      token_start = index
      while token_start > 0 && token_char?(chars[token_start - 1])
        token_start -= 1
      end
      token = String.build(token_end - token_start) do |io|
        (token_start...token_end).each { |i| io << chars[i] }
      end
      {token, token_start}
    end

    private def extend_back_cast_segment(normalized_prefix : String, start : Int32) : Int32
      if start > 0 && normalized_prefix[start - 1] == ')' && normalized_prefix[0, start]?.try(&.includes?(CAST_SEGMENT))
        depth = 0
        while start > 0
          char = normalized_prefix[start - 1]
          start -= 1
          depth += 1 if char == ')'
          depth -= 1 if char == '('
          break if depth == 0
        end
        start = scan_receiver_start(normalized_prefix, start)
      end
      start
    end

    private def strip_range_operator(receiver : String) : String
      if !receiver.includes?('"') && !receiver.includes?('\'') && (range_index = receiver.rindex(".."))
        return receiver[range_index + 2..]? || ""
      end
      receiver
    end

    # The receiver may span lines (`... end.uniq` with the `end` on its
    # own line after a do-block): walk back over the whole source up to
    # the cursor when the single-line receiver suggests a block closer
    # (`end...`) or a continuation (`.foo` on its own line); otherwise
    # the current line's prefix is enough.
    def receiver_from_line_prefix(source : String, line_number : Int32, prefix : String) : String
      single = receiver_from_prefix(prefix)
      if single.empty? || (single.starts_with?("end") && (single.size == 3 || single[3]? == '.')) || single.starts_with?('.')
        full_prefix = String.build do |io|
          source.lines(chomp: false)[0...line_number].each { |line| io << line }
          io << prefix
        end
        receiver_from_prefix(full_prefix)
      else
        single
      end
    end

    def receiver_expression_char?(char : Char)
      token_char?(char) || char == '.'
    end

    private def normalize_receiver_prefix(prefix : String) : String
      normalized_prefix = prefix
        .gsub(/\.try\s*(?:\(\s*)?&\s*\./, ".#{SAFE_TRY_SEGMENT}.")
        .gsub(/\.try\s*(?:\(\s*)?&\s*$/, ".#{SAFE_TRY_SEGMENT}.")
        .gsub(/[ \t]+\(/, "(")

      String.build do |str|
        chars = normalized_prefix.chars
        index = 0
        quote = nil.as(Char?)
        while index < chars.size
          char = chars[index]
          if quote
            index, quote = handle_normalizer_quote(chars, index, str, quote)
          elsif char.in?('"', '\'')
            quote = char
            str << char
            index += 1
          elsif char == '#'
            index = handle_normalizer_comment(chars, index, str, normalized_prefix)
          elsif char == '['
            index = consume_normalizer_bracket(chars, index, str)
          elsif char == '('
            index = consume_normalizer_paren(chars, index, str)
          elsif char == ')'
            index += 1
          else
            str << char
            index += 1
          end
        end
      end
    end

    private def handle_normalizer_quote(chars : Array(Char), index : Int32, str : String::Builder, quote : Char) : {Int32, Char?}
      char = chars[index]
      str << char
      if char == '\\'
        if escaped = chars[index + 1]?
          str << escaped
          return {index + 2, quote}
        end
      elsif char == quote
        return {index + 1, nil}
      end
      {index + 1, quote}
    end

    private def handle_normalizer_comment(chars : Array(Char), index : Int32, str : String::Builder, normalized_prefix : String) : Int32
      comment_start = index
      index += 1
      while index < chars.size && chars[index] != '\n'
        index += 1
      end
      str << normalized_prefix[comment_start...index]
      index
    end

    private def consume_normalizer_bracket(chars : Array(Char), index : Int32, str : String::Builder) : Int32
      group_start = index
      index, depth = find_group_end(chars, index + 1, '[', ']')
      if depth > 0
        (group_start...chars.size).each { |i| str << chars[i] }
        return chars.size
      end

      inner = String.build(index - group_start - 2) do |io|
        (group_start + 1...index - 1).each { |i| io << chars[i] }
      end
      str << if inner.gsub(/"[^"]*"|'[^']*'/, "").includes?("..")
        ".#{RANGE_SEGMENT}"
      else
        ".#{INDEX_SEGMENT}"
      end
      consume_of_clause(chars, index)
    end

    private def consume_of_clause(chars : Array(Char), index : Int32) : Int32
      if chars[index]? == ' ' && chars[index + 1]? == 'o' && chars[index + 2]? == 'f' && (chars[index + 3]? == ' ' || chars[index + 3]? == nil)
        index += 3
        while chars[index]? == ' '
          index += 1
        end
        while chars[index]? && token_char?(chars[index])
          index += 1
        end
      end
      index
    end

    private def consume_normalizer_paren(chars : Array(Char), index : Int32, str : String::Builder) : Int32
      group_start = index
      index, depth = find_group_end(chars, index + 1, '(', ')')
      if depth > 0
        (group_start...chars.size).each { |i| str << chars[i] }
        return chars.size
      end
      method_end = group_start
      method_start = method_end
      while method_start > 0 && token_char?(chars[method_start - 1])
        method_start -= 1
      end
      method_name = String.build(method_end - method_start) do |io|
        (method_start...method_end).each { |i| io << chars[i] }
      end
      if method_name.in?("as", "as?")
        target = String.build(index - group_start - 2) do |io|
          (group_start + 1...index - 1).each { |i| io << chars[i] }
        end
        str << ".#{CAST_SEGMENT}(#{target})"
      elsif method_name.empty? || method_name.in?("if", "unless", "while", "until", "return", "case", "?") || method_name.ends_with?(':')
        inner = String.build(index - group_start - 2) do |io|
          (group_start + 1...index - 1).each { |i| io << chars[i] }
        end
        str << normalize_receiver_prefix(inner)
      end
      index
    end

    private def find_group_end(chars : Array(Char), index : Int32, open_char : Char, close_char : Char) : {Int32, Int32}
      depth = 1
      quote = nil.as(Char?)
      while index < chars.size && depth > 0
        current = chars[index]
        index, quote, depth = handle_group_char(chars, index, current, quote, depth, open_char, close_char)
        index += 1
      end
      {index, depth}
    end

    private def handle_group_char(chars : Array(Char), index : Int32, current : Char, quote : Char?, depth : Int32, open_char : Char, close_char : Char) : {Int32, Char?, Int32}
      if quote
        if current == '\\'
          return {index + 1, quote, depth}
        elsif current == quote
          return {index, nil, depth}
        end
      elsif current.in?('"', '\'')
        return {index, current, depth}
      elsif current == open_char
        return {index, quote, depth + 1}
      elsif current == close_char
        return {index, quote, depth - 1}
      elsif current == '#'
        index += 1
        while index < chars.size && chars[index] != '\n'
          index += 1
        end
      end
      {index, quote, depth}
    end

    def token_char?(char : Char)
      char.ascii_alphanumeric? || char.in?('_', '?', '!', '@', ':')
    end

    # The token span around the cursor column (character-based), or nil
    # when the cursor is not on a token.
    def token_span(line : String, column_number : Int32) : {Int32, Int32}?
      index = normalized_column(line, column_number)
      return unless index
      return unless token_char?(line[index])

      start_index = index
      while start_index > 0 && token_char?(line[start_index - 1])
        start_index -= 1
      end

      end_index = index + 1
      while (char = line[end_index]?) && token_char?(char)
        end_index += 1
      end

      {start_index, end_index}
    end

    # The character index under the cursor, snapping to the token when the
    # cursor sits just past it (end-of-token hovers), or nil when the
    # cursor is on whitespace/punctuation.
    def normalized_column(line : String, column_number : Int32) : Int32?
      return if line.empty?

      index = PositionUtils.utf16_to_char_index(line, column_number)
      index = line.size - 1 if index >= line.size
      return if index < 0

      return index if token_char?(line[index])
      return index - 1 if index > 0 && token_char?(line[index - 1])

      nil
    end

    def instance_var_name?(name : String)
      !!(name =~ /\A@[a-zA-Z_][a-zA-Z0-9_?!]*\z/)
    end

    def class_var_name?(name : String)
      !!(name =~ /\A@@[a-zA-Z_][a-zA-Z0-9_?!]*\z/)
    end

    def local_name?(name : String)
      !!(name =~ /\A[a-z_][a-zA-Z0-9_?!]*\z/)
    end

    def type_name?(name : String)
      !!(name =~ /\A[A-Z][a-zA-Z0-9_]*(?:::[A-Z][a-zA-Z0-9_]*)*\z/)
    end

    private def root_receiver_types(source : String, line_number : Int32, analysis_column : Int32, receiver : String, query : Query) : {Array(String), Bool}
      receiver = receiver.lchop('!')

      if receiver.in?("__lightweight_index__", "[]")
        return {["Array(T)"], false}
      end

      if receiver == "nil"
        return {["Nil"], false}
      end

      if literal = literal_receiver_types(receiver)
        return {literal, false}
      end

      inference = Inference.for(
        source,
        line_number + 1,
        analysis_column + 1,
        query,
      )

      if type_name?(receiver)
        return resolve_type_name_receiver(receiver, query, inference)
      end

      if var_receiver = resolve_var_receiver(receiver, query, inference)
        return var_receiver
      end

      if local_receiver = resolve_local_or_method_receiver(receiver, query, inference)
        return local_receiver
      end

      {[] of String, false}
    end

    private def resolve_var_receiver(receiver : String, query : Query, inference : Inference?) : {Array(String), Bool}?
      if receiver == "self"
        return inference.try(&.self_types) || {[] of String, false}
      end

      if instance_var_name?(receiver)
        return {
          (inference ? inference.types_for_instance_var(receiver) : [] of String).reject(&.==("Nil")).select { |type_name| receiver_type_known?(type_name, query) },
          false,
        }
      end

      if class_var_name?(receiver)
        return {
          (inference ? inference.types_for_class_var(receiver) : [] of String).reject(&.==("Nil")).select { |type_name| receiver_type_known?(type_name, query) },
          false,
        }
      end
      nil
    end

    private def resolve_local_or_method_receiver(receiver : String, query : Query, inference : Inference?) : {Array(String), Bool}?
      return nil unless local_name?(receiver)

      if inference
        namespace = inference.current_type_name
        local_types = inference.types_for(receiver).reject(&.==("Nil")).flat_map { |type_name|
          if receiver_type_known?(type_name, query)
            [type_name]
          elsif resolved = query.resolve_type_name(type_name, namespace: namespace)
            [resolved]
          else
            [] of String
          end
        }.uniq!
        return {local_types, false} unless local_types.empty?
      end

      if inference
        if self_type_names = inference.self_types[0]?
          return_types = self_type_names.flat_map do |type_name|
            query.methods_for(type_name, class_method: inference.class_method_context?).select(&.name.==(receiver)).flat_map { |method|
              return_type_names(method.return_type, query, namespace: type_name)
            }
          end.reject(&.==("Nil")).uniq!
          return {return_types, false} unless return_types.empty?
        end
      end

      {
        query.top_level_methods.select { |method| method.name == receiver }.flat_map { |method|
          return_type_names(method.return_type, query)
        }.reject(&.==("Nil")).uniq!,
        false,
      }
    end

    private def literal_receiver_types(receiver : String) : Array(String)?
      if receiver == "true" || receiver == "false"
        return ["Bool"]
      end
      if receiver =~ /\A-?\d+_\d+\z/ || receiver =~ /\A-?\d+\z/
        return ["Int32"]
      end
      if receiver =~ /\A-?\d+\.\d+\z/ || receiver =~ /\A-?\d+[eE][+-]?\d+\z/
        return ["Float64"]
      end
      if receiver =~ /\A"[^"]*"\z/
        return ["String"]
      end
      if receiver =~ /\A'[^']*'\z/
        return ["Char"]
      end
      nil
    end

    private def resolve_type_name_receiver(receiver : String, query : Query, inference : Inference?) : {Array(String), Bool}
      resolved_name = query.resolve_type_name(receiver, namespace: inference.try(&.current_type_name))
      if resolved_name
        if constant_types = constant_value_types(resolved_name, query)
          return {constant_types, false}
        end
        return {[resolved_name], true} unless constant_shell_type?(resolved_name, query)
      end
      if inference
        constant_types = inference.types_for(receiver).reject(&.==("Nil")).select { |type_name| receiver_type_known?(type_name, query) }
        return {constant_types, false} unless constant_types.empty?
      end
      {[] of String, true}
    end

    private def safe_chained_call_types(type_names : Array(String), class_method : Bool, method_name : String, query : Query) : {Array(String), Bool}
      non_nil_types = type_names.reject(&.==("Nil")).uniq!
      return {type_names.includes?("Nil") ? ["Nil"] : [] of String, false} if non_nil_types.empty?

      resolved_types, _ = chained_call_types(non_nil_types, class_method, method_name, query)
      resolved_types = (resolved_types + ["Nil"]).uniq if type_names.includes?("Nil")
      {resolved_types, false}
    end

    private def chained_call_types(type_names : Array(String), class_method : Bool, method_name : String, query : Query) : {Array(String), Bool}
      if class_method
        valid_types = type_names.select { |type_name| receiver_type_known?(type_name, query) }.uniq!
        return {valid_types, false} if method_name == "new"
        return {valid_types, true} if method_name == "class"
      elsif method_name == "class"
        return {type_names.select { |type_name| receiver_type_known?(type_name, query) }.uniq!, true}
      end

      special_types = type_names.flat_map { |type_name| special_return_type_names(type_name, method_name, query) }.uniq!
      return {special_types, false} unless special_types.empty?

      return_types = type_names.flat_map do |type_name|
        query.methods_named(type_name, method_name, class_method: class_method).flat_map do |method|
          # `Array(T)#+` returns `Array(T)`: substitute the receiver's
          # concrete element types for the free vars so the chain keeps
          # `Array(X)` instead of an unresolvable `T`.
          return_type = TypeUtils.substitute_free_vars(method.return_type, method.free_vars, type_name)
          # A `def ...; self; end` return (Colorize's macro-generated
          # style setters) names the owner type.
          return_type = method.owner if return_type == "self"
          # Resolve bare return types (e.g. `ASTNode`) against the method's
          # own namespace, the way the compiler would.
          return_type_names(return_type, query, namespace: method.owner)
        end
      end

      # Compiler-semantic accessors (`ASTNode#type?`, base
      # `Type#parents`/`types?`/`remove_alias`) carry no usable indexed
      # return: apply the known compiler signature so chains through them
      # keep resolving (`n.type?.to_s`, `type.parents.try &.each`).
      if (return_types.empty? || return_types.all?(&.==("Nil"))) && type_names.any?(&.starts_with?("Crystal::"))
        if semantic_return = TypeUtils.semantic_accessor_return(method_name)
          return_types = TypeUtils.expand_type_names(semantic_return)
        end
      end

      {return_types.uniq, false}
    end

    private def receiver_type_known?(type_name : String, query : Query) : Bool
      # find_type_info falls back to the first generic specialization
      # (`Dispatcher` → `Dispatcher(T)`), so generic-class receivers like
      # `LSP::RequestMessage` resolve even though the index keys them
      # with their type vars.
      query.find_type_info(type_name) != nil ||
        TypeUtils.array_element_types(type_name) != nil ||
        TypeUtils.hash_value_types(type_name) != nil ||
        TypeUtils.tuple_element_types(type_name) != nil ||
        TypeUtils.named_tuple_type?(type_name)
    end

    # A recorded type entry that carries no methods and no parents is a
    # constant shell (the compiled index stores constants that way), not
    # a real type.
    private def constant_shell_type?(resolved_name : String, query : Query) : Bool
      type = query.find_type_info(resolved_name)
      return false unless type
      type.methods.empty? && type.parent_types.empty?
    end

    # A Constant-kind entry (`LSP::Log = ::Log.for(self)`) carries the
    # value's type as its single parent: the constant is an instance
    # value, so the receiver resolves to the value type's instance
    # methods.
    private def constant_value_types(resolved_name : String, query : Query) : Array(String)?
      type = query.find_type_info(resolved_name)
      return nil unless type && type.kind == TypeKind::Constant
      return nil if type.parent_types.empty?
      [type.parent_types.first]
    end

    # Container element/value types can be bare names (`Array(ArgInfo)`):
    # resolve them against the receiver's namespace so the chain keeps
    # fully-qualified entries. Bare elements from compiler generics
    # (`Array(Arg)` → `Arg`) fail the ambiguous-name tie-break, so fall
    # back to the `Crystal::`-prefixed name when it exists.
    private def resolve_types(types : Array(String), type_name : String, query : Query) : Array(String)
      types.map do |type|
        query.resolve_type_name(type, namespace: type_name) ||
          (query.find_type_info("Crystal::#{type}") ? "Crystal::#{type}" : nil) ||
          type
      end
    end

    private def special_return_type_names(type_name : String, method_name : String, query : Query) : Array(String)
      case method_name
      when "not_nil!"
        return TypeUtils.expand_type_names(type_name).reject(&.==("Nil"))
      when "tap", "each", "each_with_index", "select", "reject", "reverse_each"
        return [type_name]
      end

      if element_access = handle_special_return_element_access(type_name, method_name, query)
        return element_access
      end

      if enumerable = handle_special_return_enumerable(type_name, method_name, query)
        return enumerable
      end

      if value_types = TypeUtils.named_tuple_value_types(type_name, method_name)
        return resolve_types(value_types, type_name, query).select { |item| receiver_type_known?(item, query) || query.find_type(item) != nil }
      end

      if contract = handle_special_return_contracts(type_name, method_name, query)
        return contract
      end

      [] of String
    end

    private def handle_special_return_element_access(type_name : String, method_name : String, query : Query) : Array(String)?
      if method_name.in?("first", "last", "[]", "find!", "reduce")
        return handle_special_return_element_access_strict(type_name, method_name, query)
      elsif method_name.in?("first?", "last?", "[]?", "find", "dig")
        return handle_special_return_element_access_nilable(type_name, method_name, query)
      elsif method_name == "fetch"
        if value_types = TypeUtils.hash_value_types(type_name)
          return resolve_types(value_types, type_name, query)
        end
      end
      nil
    end

    private def handle_special_return_element_access_strict(type_name : String, method_name : String, query : Query) : Array(String)?
      if element_types = TypeUtils.array_element_types(type_name)
        return resolve_types(element_types, type_name, query).select { |item| receiver_type_known?(item, query) || query.find_type(item) != nil }
      elsif tuple_types = TypeUtils.tuple_element_types(type_name)
        if method_name == "first"
          return resolve_types(tuple_types.first? || [] of String, type_name, query)
        elsif method_name == "last"
          return resolve_types(tuple_types.last? || [] of String, type_name, query)
        end
        return resolve_types(tuple_types.flatten.uniq!, type_name, query)
      elsif value_types = TypeUtils.hash_value_types(type_name)
        return resolve_types(value_types, type_name, query).select { |item| receiver_type_known?(item, query) || query.find_type(item) != nil }
      end
      nil
    end

    private def handle_special_return_element_access_nilable(type_name : String, method_name : String, query : Query) : Array(String)?
      if element_types = TypeUtils.array_element_types(type_name)
        return (resolve_types(element_types, type_name, query) + ["Nil"]).uniq
      elsif tuple_types = TypeUtils.tuple_element_types(type_name)
        selected = if method_name == "first?"
                     tuple_types.first? || [] of String
                   elsif method_name == "last?"
                     tuple_types.last? || [] of String
                   else
                     tuple_types.flatten.uniq!
                   end
        return (resolve_types(selected, type_name, query) + ["Nil"]).uniq
      elsif value_types = TypeUtils.hash_value_types(type_name)
        return (resolve_types(value_types, type_name, query) + ["Nil"]).uniq
      elsif value_types = TypeUtils.named_tuple_all_value_types(type_name)
        return (resolve_types(value_types, type_name, query) + ["Nil"]).uniq
      end
      nil
    end

    private def handle_special_return_enumerable(type_name : String, method_name : String, query : Query) : Array(String)?
      if method_name == "compact_map"
        return [type_name] if TypeUtils.array_element_types(type_name)
      elsif method_name == "flat_map"
        if element_types = TypeUtils.enumerable_element_types(type_name)
          return ["Array(#{resolve_types(element_types, type_name, query).join(" | ")})"]
        end
      elsif method_name == "flatten"
        if TypeUtils.array_element_types(type_name)
          return [type_name]
        elsif tuple_types = TypeUtils.tuple_element_types(type_name)
          return ["Array(#{resolve_types(tuple_types.flatten.uniq!, type_name, query).join(" | ")})"]
        end
      end
      nil
    end

    private def handle_special_return_contracts(type_name : String, method_name : String, query : Query) : Array(String)?
      contracts = query.method_contracts_for(type_name, method_name)
      return nil unless contracts

      contract_types = [] of String
      contracts.each do |contract|
        case contract.kind
        when .preserve_receiver?
          contract_types.concat(contract.types)
        when .return_element?, .return_value?
          contract_types.concat(contract.types)
        when .return_element_or_nil?, .return_value_or_nil?
          contract_types.concat(contract.types)
          contract_types << "Nil"
        end
      end
      contract_types = contract_types.uniq
      unless contract_types.empty?
        unless contract_types.all?(&.==("Nil")) && type_name.starts_with?("Crystal::") && TypeUtils.semantic_accessor_return(method_name)
          return contract_types.flat_map { |contract_type| return_type_names(contract_type, query, namespace: type_name) }.uniq!
        end
      end
      nil
    end

    private def return_type_names(return_type : String?, query : Query, namespace : String? = nil) : Array(String)
      return [] of String unless return_type

      TypeUtils.expand_type_names(return_type).compact_map do |type_name|
        # `: self?`-style returns resolve to the method's owner.
        if type_name == "self"
          next namespace ? namespace : nil
        end
        # Resolve plain names against the query (and the enclosing namespace
        # when known, e.g. a getter's `Workspace` in `Crystalline::Controller`);
        # generic/structured names (Array(T), Tuple(...)) are known as-is.
        resolved = query.resolve_type_name(type_name, namespace) || type_name
        next unless receiver_type_known?(resolved, query)
        resolved
      end
    end
  end
end
