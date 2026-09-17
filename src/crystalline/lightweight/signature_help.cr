require "lsp/server"
require "../source_mask"
require "../broken_source_fixer"
require "./query"
require "./resolver"
require "./inference"

module Crystalline::Lightweight
  class SignatureHelp
    KEYWORDS = %w[
      def class module struct enum alias lib macro if unless while until
      case when begin rescue ensure return yield next break select
    ]

    record CallSite, line : Int32, col : Int32, commas : Int32

    def self.signature_help(source : String, line_number : Int32, column_number : Int32, query : Query) : LSP::SignatureHelp?
      new(source, line_number, column_number, query).run
    end

    def initialize(@source : String, @line_number : Int32, @column_number : Int32, @query : Query)
    end

    def run : LSP::SignatureHelp?
      lines = @source.lines(chomp: false)
      line = lines[@line_number]?
      return nil unless line

      char_col = PositionUtils.utf16_to_char_index(line, @column_number)
      mask = SourceMask.new(@source)
      return nil if cursor_in_comment?(line, char_col)

      call_site = scan_for_call_site(lines, mask, char_col)
      return nil unless call_site

      call_head = extract_call_head(lines[call_site.line], call_site.col)
      return nil unless call_head

      receiver, method_name = call_head
      methods = resolve_methods(receiver, method_name, call_site.line, call_site.col)
      return nil if methods.empty?

      build_signature_help(methods, call_site.commas)
    end

    private def cursor_in_comment?(line : String, char_col : Int32) : Bool
      quote = nil.as(Char?)
      line.each_char_with_index do |char, idx|
        return false if idx > char_col
        if quote
          quote = nil if char == quote && (idx == 0 || line[idx - 1] != '\\')
        elsif char.in?('"', '\'')
          quote = char
        elsif char == '#'
          return true if idx <= char_col
        end
      end
      false
    end

    private def scan_for_call_site(lines : Array(String), mask : SourceMask, char_col : Int32) : CallSite?
      paren_depth = 0
      bracket_depth = 0
      brace_depth = 0
      commas = 0

      curr_line = @line_number
      while curr_line >= 0 && curr_line >= @line_number - 50
        line = lines[curr_line]
        start_col = (curr_line == @line_number) ? char_col - 1 : line.size - 1

        res = scan_line_backwards(line, curr_line, start_col, mask, paren_depth, bracket_depth, brace_depth, commas)
        case res
        when CallSite
          return res
        when Nil
          return nil
        else
          paren_depth, bracket_depth, brace_depth, commas = res
        end
        curr_line -= 1
      end
      nil
    end

    private def scan_line_backwards(
      line : String,
      curr_line : Int32,
      start_col : Int32,
      mask : SourceMask,
      paren_depth : Int32,
      bracket_depth : Int32,
      brace_depth : Int32,
      commas : Int32,
    ) : CallSite | Tuple(Int32, Int32, Int32, Int32) | Nil
      depths = {paren_depth, bracket_depth, brace_depth, commas}
      col = start_col
      while col >= 0
        unless mask.comment_or_string?(curr_line, col)
          case step = process_scan_char(line[col], curr_line, col, depths)
          when CallSite, Nil
            return step
          else
            depths = step
          end
        end
        col -= 1
      end
      depths
    end

    private def at_root_depth?(paren : Int32, bracket : Int32, brace : Int32) : Bool
      paren == 0 && bracket == 0 && brace == 0
    end

    private def process_scan_char(
      char : Char,
      curr_line : Int32,
      col : Int32,
      depths : Tuple(Int32, Int32, Int32, Int32),
    ) : CallSite | Tuple(Int32, Int32, Int32, Int32) | Nil
      paren, bracket, brace, commas = depths
      if char == '('
        return CallSite.new(curr_line, col, commas) if paren == 0
        return {paren - 1, bracket, brace, commas}
      end

      if at_root_depth?(paren, bracket, brace)
        return nil if char == ';'
        return {paren, bracket, brace, commas + 1} if char == ','
      end

      adjusted = adjust_depth(char, paren, bracket, brace)
      return nil unless adjusted

      {adjusted[0], adjusted[1], adjusted[2], commas}
    end

    private def adjust_depth(char : Char, paren : Int32, bracket : Int32, brace : Int32) : Tuple(Int32, Int32, Int32)?
      case char
      when ')' then {paren + 1, bracket, brace}
      when ']' then {paren, bracket + 1, brace}
      when '}' then {paren, bracket, brace + 1}
      when '['
        return nil if bracket == 0
        {paren, bracket - 1, brace}
      when '{'
        return nil if brace == 0
        {paren, bracket, brace - 1}
      else
        {paren, bracket, brace}
      end
    end

    private def extract_call_head(line : String, call_col : Int32) : Tuple(String?, String)?
      prefix = line[0...call_col].rstrip
      return nil if prefix.empty?

      idx = prefix.size - 1
      idx -= 1 if idx >= 0 && prefix[idx].in?('?', '!')
      while idx >= 0 && (prefix[idx].ascii_alphanumeric? || prefix[idx] == '_')
        idx -= 1
      end

      method_name = prefix[(idx + 1)..]
      return nil if method_name.empty?
      return nil if KEYWORDS.includes?(method_name)

      before = prefix[0..idx].rstrip
      receiver = extract_receiver_string(before)
      {receiver, method_name}
    end

    private def extract_receiver_string(before : String) : String?
      if before.ends_with?('.')
        before[0...before.size - 1].rstrip
      elsif before.ends_with?("::")
        before[0...before.size - 2].rstrip
      else
        nil
      end
    end

    private def resolve_methods(receiver : String?, method_name : String, call_line : Int32, call_col : Int32) : Array(MethodInfo)
      if receiver
        resolve_qualified_methods(receiver, method_name, call_line, call_col)
      else
        resolve_unqualified_methods(method_name, call_line, call_col)
      end
    end

    private def fix_source_for_inference : String
      Crystal::Parser.parse(@source)
      @source
    rescue
      BrokenSourceFixer.fix(@source)
    end

    private def resolve_qualified_methods(receiver : String, method_name : String, call_line : Int32, call_col : Int32) : Array(MethodInfo)
      fixed_source = fix_source_for_inference
      resolved_receiver = Resolver.receiver_from_line_prefix(fixed_source, call_line, receiver)
      receiver_types, is_class = Resolver.receiver_types(fixed_source, call_line, call_col, resolved_receiver, @query)
      return [] of MethodInfo if receiver_types.empty?

      methods = [] of MethodInfo
      receiver_types.each do |type_name|
        matched = @query.methods_named(type_name, method_name, class_method: is_class, include_macros: true)
        methods.concat(matched)
      end

      if methods.empty? && !is_class
        methods.concat(@query.methods_named("Object", method_name, class_method: false, include_macros: true))
      end
      methods
    end

    private def resolve_unqualified_methods(method_name : String, call_line : Int32, call_col : Int32) : Array(MethodInfo)
      fixed_source = fix_source_for_inference
      if inference = Inference.for(fixed_source, call_line + 1, call_col + 1, @query)
        self_types, is_class = inference.self_types
        self_types.each do |self_type|
          methods = @query.methods_named(self_type, method_name, class_method: is_class, include_macros: true)
          return methods unless methods.empty?
        end
      end

      top_level = @query.top_level_methods.select { |method| method.name == method_name }
      return top_level unless top_level.empty?

      methods = @query.methods_named("Object", method_name, class_method: false, include_macros: true)
      return methods unless methods.empty?

      @query.methods_named("Kernel", method_name, class_method: false, include_macros: true)
    end

    private def build_signature_help(methods : Array(MethodInfo), commas : Int32) : LSP::SignatureHelp
      signatures = methods.map { |method| build_signature(method) }
      active_sig = select_active_signature(signatures, commas)

      LSP::SignatureHelp.new(
        signatures: signatures,
        active_signature: active_sig,
        active_parameter: commas,
      )
    end

    private def select_active_signature(signatures : Array(LSP::SignatureInformation), commas : Int32) : Int32
      match = signatures.index do |sig|
        count = sig.parameters.try(&.size) || 0
        count > commas
      end
      match || 0
    end

    private def build_signature(method : MethodInfo) : LSP::SignatureInformation
      params = method.args.map { |arg| build_parameter(arg) }

      formatted_args = method.args.map do |arg|
        format_arg(arg)
      end.join(", ")

      label = String.build do |str|
        str << method.name << "(" << formatted_args << ")"
        str << " : " << method.return_type if method.return_type
      end

      doc = method.doc.presence.try do |doc_text|
        LSP::MarkupContent.new(kind: LSP::MarkupKind::MarkDown, value: doc_text)
      end

      LSP::SignatureInformation.new(
        label: label,
        documentation: doc,
        parameters: params,
      )
    end

    private def build_parameter(arg : ArgInfo) : LSP::ParameterInformation
      LSP::ParameterInformation.new(label: format_arg(arg))
    end

    private def format_arg(arg : ArgInfo) : String
      String.build do |io|
        io << arg.name
        io << " : " << arg.restriction if arg.restriction
        io << " = " << arg.default_value if arg.default_value
      end
    end
  end
end
