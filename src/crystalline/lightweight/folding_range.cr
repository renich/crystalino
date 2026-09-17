require "lsp/server"
require "compiler/crystal/syntax"
require "../broken_source_fixer"

module Crystalline::Lightweight
  class FoldingRange
    def self.folding_ranges(source : String) : Array(LSP::FoldingRange)?
      new(source).folding_ranges
    end

    def initialize(@source : String)
      @lines = @source.lines(chomp: false)
    end

    def folding_ranges : Array(LSP::FoldingRange)?
      return if @lines.empty?

      ranges = [] of LSP::FoldingRange
      collect_comment_ranges(ranges)
      collect_import_ranges(ranges)

      ast = parse_ast
      if ast
        collect_ast_ranges(ast, ranges)
      else
        collect_indent_ranges(ranges)
      end

      ranges.sort_by! { |range| {range.start_line, range.end_line} }
      ranges.uniq! { |range| {range.start_line, range.end_line} }
      ranges.empty? ? nil : ranges
    end

    private def parse_ast : Crystal::ASTNode?
      Crystal::Parser.new(@source).parse
    rescue
      parse_fixed_source
    end

    private def parse_fixed_source : Crystal::ASTNode?
      fixed = BrokenSourceFixer.fix(@source)
      Crystal::Parser.new(fixed).parse
    rescue
      nil
    end

    private def collect_comment_ranges(ranges : Array(LSP::FoldingRange))
      streak_start : Int32? = nil

      @lines.each_with_index do |line, index|
        if line.lstrip.starts_with?('#')
          streak_start ||= index
        else
          flush_streak(ranges, streak_start, index - 1, LSP::FoldingRangeKind::Comment)
          streak_start = nil
        end
      end

      flush_streak(ranges, streak_start, @lines.size - 1, LSP::FoldingRangeKind::Comment)
    end

    private def collect_import_ranges(ranges : Array(LSP::FoldingRange))
      streak_start : Int32? = nil

      @lines.each_with_index do |line, index|
        if line.lstrip.starts_with?("require ")
          streak_start ||= index
        else
          flush_streak(ranges, streak_start, index - 1, LSP::FoldingRangeKind::Imports)
          streak_start = nil
        end
      end

      flush_streak(ranges, streak_start, @lines.size - 1, LSP::FoldingRangeKind::Imports)
    end

    private def flush_streak(
      ranges : Array(LSP::FoldingRange),
      start_index : Int32?,
      end_index : Int32,
      kind : LSP::FoldingRangeKind,
    )
      return unless start_index
      return unless end_index > start_index

      ranges << LSP::FoldingRange.new(
        start_line: start_index,
        end_line: end_index,
        kind: kind
      )
    end

    private def collect_ast_ranges(ast : Crystal::ASTNode, ranges : Array(LSP::FoldingRange))
      visitor = AstFoldVisitor.new
      ast.accept(visitor)
      ranges.concat(visitor.ranges)
    end

    private def collect_indent_ranges(ranges : Array(LSP::FoldingRange))
      stack = [] of {Int32, Int32}

      @lines.each_with_index do |line, index|
        stripped = line.strip
        next if stripped.empty? || stripped.starts_with?('#')

        indent = line.size - line.lstrip.size
        handle_indent_line(stack, ranges, stripped, indent, index)
      end
    end

    private def handle_indent_line(
      stack : Array({Int32, Int32}),
      ranges : Array(LSP::FoldingRange),
      stripped : String,
      indent : Int32,
      line_index : Int32,
    )
      if block_opener?(stripped)
        stack << {line_index, indent}
      elsif stripped == "end" || stripped.starts_with?("end ")
        pop_matching_opener(stack, ranges, line_index)
      end
    end

    private def pop_matching_opener(
      stack : Array({Int32, Int32}),
      ranges : Array(LSP::FoldingRange),
      line_index : Int32,
    )
      return if stack.empty?

      start_line, _ = stack.pop
      return unless line_index > start_line

      ranges << LSP::FoldingRange.new(start_line: start_line, end_line: line_index)
    end

    private def block_opener?(line : String) : Bool
      first_word = line.split.first?
      return false unless first_word

      first_word.in?("class", "module", "struct", "enum", "def", "macro", "if", "unless", "case", "while", "until", "begin") || line.ends_with?(" do")
    end
  end

  class AstFoldVisitor < Crystal::Visitor
    getter ranges : Array(LSP::FoldingRange)

    def initialize
      @ranges = [] of LSP::FoldingRange
    end

    private def add_node_range(node : Crystal::ASTNode, kind : LSP::FoldingRangeKind? = nil)
      loc = node.location
      end_loc = node.end_location
      return unless loc && end_loc

      start_line = loc.line_number - 1
      end_line = end_loc.line_number - 1
      return unless end_line > start_line

      @ranges << LSP::FoldingRange.new(
        start_line: start_line,
        end_line: end_line,
        kind: kind
      )
    end

    def visit(node : Crystal::Expressions)
      true
    end

    def visit(node : Crystal::ClassDef | Crystal::ModuleDef | Crystal::EnumDef | Crystal::Alias)
      add_node_range(node)
      true
    end

    def visit(node : Crystal::Def | Crystal::Macro)
      add_node_range(node)
      true
    end

    def visit(node : Crystal::Block)
      add_node_range(node)
      true
    end

    def visit(node : Crystal::If | Crystal::Unless | Crystal::Case | Crystal::While | Crystal::Until)
      add_node_range(node)
      true
    end

    def visit(node : Crystal::ExceptionHandler)
      add_node_range(node)
      true
    end

    def visit(node : Crystal::StringLiteral)
      add_node_range(node)
      true
    end

    def visit(node : Crystal::ArrayLiteral | Crystal::HashLiteral | Crystal::NamedTupleLiteral)
      add_node_range(node)
      true
    end

    def visit(node : Crystal::ASTNode)
      true
    end
  end
end
