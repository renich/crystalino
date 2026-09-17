require "lsp/server"
require "compiler/crystal/syntax"
require "../position_utils"
require "../broken_source_fixer"
require "./resolver"

module Crystalino::Lightweight
  class SelectionRange
    def self.selection_ranges(source : String, positions : Array(LSP::Position)) : Array(LSP::SelectionRange)?
      new(source, positions).selection_ranges
    end

    def initialize(@source : String, @positions : Array(LSP::Position))
      @lines = @source.lines(chomp: false)
    end

    def selection_ranges : Array(LSP::SelectionRange)?
      return if @lines.empty? || @positions.empty?

      ast = parse_ast
      @positions.map { |pos| selection_range_at(pos, ast) }
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

    private def selection_range_at(pos : LSP::Position, ast : Crystal::ASTNode?) : LSP::SelectionRange
      ranges = [] of LSP::Range
      collect_ast_ranges(pos, ast, ranges) if ast
      ensure_fallback_ranges(pos, ranges)
      deduped = deduplicate_ranges(ranges)
      build_selection_chain(deduped)
    end

    private def collect_ast_ranges(pos : LSP::Position, ast : Crystal::ASTNode, ranges : Array(LSP::Range))
      line_1 = pos.line + 1
      line_str = @lines[pos.line]? || ""
      char_1 = PositionUtils.utf16_to_char_index(line_str, pos.character) + 1

      collector = RangeCollector.new(@lines, line_1, char_1)
      ast.accept(collector)

      sorted_nodes = collector.matching_nodes.sort_by { |node| node_span_size(node) }
      sorted_nodes.each do |node|
        range = lsp_range_from_node(node)
        ranges << range if range
      end
    end

    private def ensure_fallback_ranges(pos : LSP::Position, ranges : Array(LSP::Range))
      line_idx = pos.line
      line_str = @lines[line_idx]? || ""

      if span = Resolver.token_span(line_str, pos.character)
        start_char = PositionUtils.char_to_utf16_index(line_str, span[0])
        end_char = PositionUtils.char_to_utf16_index(line_str, span[1])
        token_range = LSP::Range.new(
          start: LSP::Position.new(line: line_idx, character: start_char),
          end: LSP::Position.new(line: line_idx, character: end_char)
        )
        ranges.unshift(token_range)
      end

      line_end_char = PositionUtils.char_to_utf16_index(line_str, line_str.size)
      ranges << LSP::Range.new(
        start: LSP::Position.new(line: line_idx, character: 0),
        end: LSP::Position.new(line: line_idx, character: line_end_char)
      )

      last_line_idx = @lines.size - 1
      last_line_str = @lines[last_line_idx]? || ""
      doc_end_char = PositionUtils.char_to_utf16_index(last_line_str, last_line_str.size)
      ranges << LSP::Range.new(
        start: LSP::Position.new(line: 0, character: 0),
        end: LSP::Position.new(line: last_line_idx, character: doc_end_char)
      )
    end

    private def deduplicate_ranges(ranges : Array(LSP::Range)) : Array(LSP::Range)
      deduped = [] of LSP::Range
      ranges.each do |range|
        next if deduped.any? { |existing| same_range?(existing, range) }

        deduped << range
      end
      deduped
    end

    private def same_range?(a : LSP::Range, b : LSP::Range) : Bool
      a.start.line == b.start.line &&
        a.start.character == b.start.character &&
        a.end.line == b.end.line &&
        a.end.character == b.end.character
    end

    private def build_selection_chain(ranges : Array(LSP::Range)) : LSP::SelectionRange
      curr : LSP::SelectionRange? = nil
      ranges.reverse_each do |range|
        curr = LSP::SelectionRange.new(range: range, parent: curr)
      end
      curr || LSP::SelectionRange.new(
        range: LSP::Range.new(
          start: LSP::Position.new(line: 0, character: 0),
          end: LSP::Position.new(line: 0, character: 0)
        ),
        parent: nil
      )
    end

    private def node_span_size(node : Crystal::ASTNode) : Int32
      loc = node.location
      end_loc = node.end_location || loc
      return 0 unless loc && end_loc

      lines_diff = end_loc.line_number - loc.line_number
      lines_diff * 1000 + (end_loc.column_number - loc.column_number)
    end

    private def lsp_range_from_node(node : Crystal::ASTNode) : LSP::Range?
      loc = node.location
      return unless loc

      end_loc = node.end_location || loc
      start_line = loc.line_number - 1
      end_line = end_loc.line_number - 1
      start_line_str = @lines[start_line]? || ""
      end_line_str = @lines[end_line]? || ""

      start_char = PositionUtils.char_to_utf16_index(start_line_str, loc.column_number - 1)
      end_col = compute_end_column(node, loc, end_loc)
      end_char = PositionUtils.char_to_utf16_index(end_line_str, end_col - 1)

      LSP::Range.new(
        start: LSP::Position.new(line: start_line, character: start_char),
        end: LSP::Position.new(line: end_line, character: end_char)
      )
    end

    private def compute_end_column(node : Crystal::ASTNode, loc : Crystal::Location, end_loc : Crystal::Location) : Int32
      if loc.line_number == end_loc.line_number && loc.column_number == end_loc.column_number
        if node.responds_to?(:name)
          return loc.column_number + node.name.to_s.size
        elsif node.responds_to?(:value)
          return loc.column_number + node.to_s.size
        end
      end
      end_loc.column_number
    end
  end

  class RangeCollector < Crystal::Visitor
    getter matching_nodes = [] of Crystal::ASTNode

    def initialize(@lines : Array(String), @line : Int32, @col : Int32)
    end

    def visit(node : Crystal::ASTNode)
      if loc = node.location
        end_loc = node.end_location || loc
        if encloses?(loc, end_loc)
          @matching_nodes << node
        end
      end
      true
    end

    private def encloses?(start_loc : Crystal::Location, end_loc : Crystal::Location) : Bool
      return false if @line < start_loc.line_number || @line > end_loc.line_number
      if @line == start_loc.line_number && @col < start_loc.column_number
        return false
      end
      if @line == end_loc.line_number && @col > end_loc.column_number
        return false
      end
      true
    end
  end
end
