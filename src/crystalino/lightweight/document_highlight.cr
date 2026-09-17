require "lsp/server"
require "compiler/crystal/syntax"
require "../position_utils"
require "../broken_source_fixer"
require "./resolver"

module Crystalino::Lightweight
  class DocumentHighlight
    def self.highlights(source : String, line_number : Int32, column_number : Int32) : Array(LSP::DocumentHighlight)?
      new(source, line_number, column_number).highlights
    end

    def initialize(@source : String, @line_number : Int32, @column_number : Int32)
      @lines = @source.lines(chomp: false)
    end

    def highlights : Array(LSP::DocumentHighlight)?
      line = @lines[@line_number]?
      return unless line

      span = Resolver.token_span(line, @column_number)
      return unless span

      start_index, end_index = span
      token = line[start_index...end_index]?
      return if token.nil? || token.empty?

      ast = parse_ast
      if ast
        ast_highlights = collect_ast_highlights(ast, token)
        return ast_highlights if ast_highlights && !ast_highlights.empty?
      end

      collect_textual_highlights(token)
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

    private def collect_ast_highlights(ast : Crystal::ASTNode, token : String) : Array(LSP::DocumentHighlight)?
      visitor = HighlightVisitor.new(@source, @lines, token, @line_number + 1, @column_number + 1)
      ast.accept(visitor)
      highlights = visitor.results
      highlights.empty? ? nil : highlights
    end

    private def collect_textual_highlights(token : String) : Array(LSP::DocumentHighlight)?
      pattern = token_boundary_regex(token)
      results = [] of LSP::DocumentHighlight

      @lines.each_with_index do |line, line_idx|
        line.scan(pattern) do |match|
          match_start = match.begin(0)
          next unless match_start

          start_char = PositionUtils.char_to_utf16_index(line, match_start)
          end_char = PositionUtils.char_to_utf16_index(line, match_start + token.size)
          range = LSP::Range.new(
            start: LSP::Position.new(line: line_idx, character: start_char),
            end: LSP::Position.new(line: line_idx, character: end_char)
          )
          results << LSP::DocumentHighlight.new(
            range: range,
            kind: LSP::DocumentHighlightKind::Text
          )
        end
      end

      results.empty? ? nil : results
    end

    private def token_boundary_regex(token : String) : Regex
      escaped = Regex.escape(token)
      if token.starts_with?('@')
        Regex.new("(?<![a-zA-Z0-9_@])#{escaped}(?![a-zA-Z0-9_?!])")
      else
        Regex.new("(?<![a-zA-Z0-9_@])#{escaped}(?![a-zA-Z0-9_?!])")
      end
    end
  end

  class HighlightVisitor < Crystal::Visitor
    getter results : Array(LSP::DocumentHighlight)
    @scope_def : Crystal::Def?

    def initialize(
      @source : String,
      @lines : Array(String),
      @target_name : String,
      @cursor_line : Int32,
      @cursor_col : Int32,
    )
      @results = [] of LSP::DocumentHighlight
      @scope_def = find_enclosing_def
      @is_ivar = @target_name.starts_with?('@') && !@target_name.starts_with?("@@")
      @is_cvar = @target_name.starts_with?("@@")
      @is_const = @target_name =~ /\A[A-Z]/
      @is_local = !@is_ivar && !@is_cvar && !@is_const && local_in_scope?
    end

    private def find_enclosing_def : Crystal::Def?
      finder = DefFinder.new(@cursor_line, @cursor_col)
      begin
        Crystal::Parser.new(@source).parse.accept(finder)
      rescue
        nil
      end
      finder.enclosing_def
    end

    private def local_in_scope? : Bool
      scope = @scope_def
      return false unless scope

      checker = LocalChecker.new(@target_name)
      scope.accept(checker)
      checker.found?
    end

    def visit(node : Crystal::Assign)
      handle_assignment(node.target)
      node.value.accept(self)
      false
    end

    def visit(node : Crystal::OpAssign)
      handle_assignment(node.target)
      node.value.accept(self)
      false
    end

    def visit(node : Crystal::MultiAssign)
      node.targets.each { |target| handle_assignment(target) }
      node.values.each(&.accept(self))
      false
    end

    def visit(node : Crystal::Arg)
      if node.name == @target_name && in_scope?(node)
        add_highlight(node, LSP::DocumentHighlightKind::Write)
      end
      node.default_value.try(&.accept(self))
      false
    end

    def visit(node : Crystal::Var)
      if node.name == @target_name && in_scope?(node)
        add_highlight(node, LSP::DocumentHighlightKind::Read)
      end
      true
    end

    def visit(node : Crystal::InstanceVar)
      if @is_ivar && node.name == @target_name
        add_highlight(node, LSP::DocumentHighlightKind::Read)
      end
      true
    end

    def visit(node : Crystal::ClassVar)
      if @is_cvar && node.name == @target_name
        add_highlight(node, LSP::DocumentHighlightKind::Read)
      end
      true
    end

    def visit(node : Crystal::Def)
      if !@is_local && !@is_ivar && !@is_cvar && !@is_const && node.name == @target_name
        loc = node.name_location || node.location
        add_range_highlight(loc, @target_name.size, LSP::DocumentHighlightKind::Write) if loc
      end
      node.args.each(&.accept(self))
      node.body.accept(self)
      false
    end

    def visit(node : Crystal::Call)
      if !@is_local && !@is_ivar && !@is_cvar && !@is_const && node.name == @target_name
        loc = node.name_location || node.location
        add_range_highlight(loc, @target_name.size, LSP::DocumentHighlightKind::Read) if loc
      end
      node.obj.try(&.accept(self))
      node.args.each(&.accept(self))
      node.block.try(&.accept(self))
      node.named_args.try(&.each(&.value.accept(self)))
      false
    end

    def visit(node : Crystal::ClassDef)
      check_type_name(node.name)
      node.body.accept(self)
      false
    end

    def visit(node : Crystal::ModuleDef)
      check_type_name(node.name)
      node.body.accept(self)
      false
    end

    def visit(node : Crystal::EnumDef)
      check_type_name(node.name)
      node.members.each(&.accept(self))
      false
    end

    def visit(node : Crystal::Alias)
      check_type_name(node.name)
      node.value.accept(self)
      false
    end

    def visit(node : Crystal::Path)
      if @is_const && path_matches?(node)
        loc = node.location
        add_range_highlight(loc, @target_name.size, LSP::DocumentHighlightKind::Read) if loc
      end
      true
    end

    def visit(node : Crystal::ASTNode)
      true
    end

    private def handle_assignment(target : Crystal::ASTNode)
      case target
      when Crystal::Var
        handle_var_assignment(target)
      when Crystal::InstanceVar
        handle_ivar_assignment(target)
      when Crystal::ClassVar
        handle_cvar_assignment(target)
      else
        target.accept(self)
      end
    end

    private def handle_var_assignment(target : Crystal::Var)
      return unless @is_local && target.name == @target_name && in_scope?(target)

      add_highlight(target, LSP::DocumentHighlightKind::Write)
    end

    private def handle_ivar_assignment(target : Crystal::InstanceVar)
      return unless @is_ivar && target.name == @target_name

      add_highlight(target, LSP::DocumentHighlightKind::Write)
    end

    private def handle_cvar_assignment(target : Crystal::ClassVar)
      return unless @is_cvar && target.name == @target_name

      add_highlight(target, LSP::DocumentHighlightKind::Write)
    end

    private def check_type_name(path : Crystal::ASTNode)
      return unless @is_const
      return unless path.is_a?(Crystal::Path) && path_matches?(path)

      loc = path.location
      add_range_highlight(loc, @target_name.size, LSP::DocumentHighlightKind::Write) if loc
    end

    private def path_matches?(path : Crystal::Path) : Bool
      path.names.last? == @target_name
    end

    private def in_scope?(node : Crystal::ASTNode) : Bool
      scope = @scope_def
      return true unless scope

      start_loc = scope.location
      end_loc = scope.end_location
      return true unless start_loc && end_loc

      node_loc = node.location
      return false unless node_loc

      node_loc.line_number >= start_loc.line_number && node_loc.line_number <= end_loc.line_number
    end

    private def add_highlight(node : Crystal::ASTNode, kind : LSP::DocumentHighlightKind)
      loc = node.location
      return unless loc

      add_range_highlight(loc, @target_name.size, kind)
    end

    private def add_range_highlight(loc : Crystal::Location, length : Int32, kind : LSP::DocumentHighlightKind)
      line_idx = loc.line_number - 1
      line_str = @lines[line_idx]?
      return unless line_str

      char_idx = loc.column_number - 1
      start_char = PositionUtils.char_to_utf16_index(line_str, char_idx)
      end_char = PositionUtils.char_to_utf16_index(line_str, char_idx + length)

      range = LSP::Range.new(
        start: LSP::Position.new(line: line_idx, character: start_char),
        end: LSP::Position.new(line: line_idx, character: end_char)
      )
      @results << LSP::DocumentHighlight.new(range: range, kind: kind)
    end
  end

  class DefFinder < Crystal::Visitor
    getter enclosing_def : Crystal::Def?

    def initialize(@cursor_line : Int32, @cursor_col : Int32)
    end

    def visit(node : Crystal::Def)
      start_loc = node.location
      end_loc = node.end_location
      if start_loc && end_loc && cursor_within?(start_loc, end_loc)
        @enclosing_def = node
      end
      true
    end

    def visit(node : Crystal::ASTNode)
      true
    end

    private def cursor_within?(start_loc : Crystal::Location, end_loc : Crystal::Location) : Bool
      return false if @cursor_line < start_loc.line_number || @cursor_line > end_loc.line_number
      if @cursor_line == start_loc.line_number && @cursor_col < start_loc.column_number
        return false
      end
      if @cursor_line == end_loc.line_number && @cursor_col > end_loc.column_number
        return false
      end
      true
    end
  end

  class LocalChecker < Crystal::Visitor
    getter? found = false

    def initialize(@target_name : String)
    end

    def visit(node : Crystal::Var | Crystal::Arg)
      @found = true if node.name == @target_name
      true
    end

    def visit(node : Crystal::Assign | Crystal::OpAssign)
      case target = node.target
      when Crystal::Var
        @found = true if target.name == @target_name
      else
        nil
      end
      true
    end

    def visit(node : Crystal::ASTNode)
      true
    end
  end
end
