require "lsp/server"
require "compiler/crystal/syntax"
require "../position_utils"
require "../broken_source_fixer"

module Crystalline::Lightweight
  class SemanticTokens
    TOKEN_TYPES = [
      "type",      # 0
      "class",     # 1
      "struct",    # 2
      "enum",      # 3
      "interface", # 4
      "parameter", # 5
      "variable",  # 6
      "property",  # 7
      "function",  # 8
      "method",    # 9
      "macro",     # 10
      "keyword",   # 11
      "comment",   # 12
      "string",    # 13
      "number",    # 14
      "operator",  # 15
    ]

    TOKEN_MODIFIERS = [
      "declaration",    # 1 << 0
      "definition",     # 1 << 1
      "readonly",       # 1 << 2
      "static",         # 1 << 3
      "defaultLibrary", # 1 << 4
    ]

    record RawToken,
      line : Int32,
      character : Int32,
      length : Int32,
      token_type : Int32,
      token_modifiers : Int32

    def self.legend : LSP::SemanticTokensLegend
      LSP::SemanticTokensLegend.new(
        token_types: TOKEN_TYPES,
        token_modifiers: TOKEN_MODIFIERS
      )
    end

    def self.tokens(source : String) : LSP::SemanticTokens?
      new(source).tokens
    end

    def initialize(@source : String)
      @lines = @source.lines(chomp: false)
    end

    def tokens : LSP::SemanticTokens?
      return if @lines.empty?

      raw_tokens = [] of RawToken
      collect_comments(raw_tokens)

      ast = parse_ast
      if ast
        collect_ast_tokens(ast, raw_tokens)
      else
        collect_lexer_tokens(raw_tokens)
      end

      return if raw_tokens.empty?

      raw_tokens.sort_by! { |token| {token.line, token.character} }
      deduped = deduplicate_tokens(raw_tokens)
      data = encode_delta_data(deduped)

      LSP::SemanticTokens.new(data: data)
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

    private def collect_lexer_tokens(raw_tokens : Array(RawToken))
      lexer = Crystal::Lexer.new(@source)
      loop do
        tok = lexer.next_token
        break if tok.type.eof?

        append_lexer_token(tok, raw_tokens)
      end
    rescue
      nil
    end

    private def append_lexer_token(tok : Crystal::Token, raw_tokens : Array(RawToken))
      token_type = map_lexer_token_type(tok)
      return unless token_type

      line_idx = tok.line_number - 1
      line_str = @lines[line_idx]?
      return unless line_str

      char_idx = tok.column_number - 1
      return if char_idx < 0 || char_idx >= line_str.size

      tok_str = tok.to_s
      return if tok_str.empty?

      start_char = PositionUtils.char_to_utf16_index(line_str, char_idx)
      end_char = PositionUtils.char_to_utf16_index(line_str, char_idx + tok_str.size)
      utf16_len = end_char - start_char

      raw_tokens << RawToken.new(
        line: line_idx,
        character: start_char,
        length: utf16_len,
        token_type: token_type,
        token_modifiers: 0
      )
    end

    private def map_lexer_token_type(tok : Crystal::Token) : Int32?
      case tok.type
      when .ident?
        tok.value.is_a?(Crystal::Keyword) ? 11 : 6
      when .const?
        0
      when .instance_var?, .class_var?
        7
      when .string?, .char?
        13
      when .number?
        14
      else
        nil
      end
    end

    private def collect_comments(raw_tokens : Array(RawToken))
      @lines.each_with_index do |line, line_idx|
        comment_idx = line.index('#')
        next unless comment_idx

        content = line[comment_idx..]
        start_char = PositionUtils.char_to_utf16_index(line, comment_idx)
        length = PositionUtils.char_to_utf16_index(content, content.size)

        raw_tokens << RawToken.new(
          line: line_idx,
          character: start_char,
          length: length,
          token_type: 12, # comment
          token_modifiers: 0
        )
      end
    end

    private def collect_ast_tokens(ast : Crystal::ASTNode, raw_tokens : Array(RawToken))
      visitor = TokenVisitor.new(@lines, raw_tokens)
      ast.accept(visitor)
    end

    private def deduplicate_tokens(tokens : Array(RawToken)) : Array(RawToken)
      deduped = [] of RawToken
      tokens.each do |tok|
        next if deduped.any? { |existing| existing.line == tok.line && existing.character == tok.character }

        deduped << tok
      end
      deduped
    end

    private def encode_delta_data(tokens : Array(RawToken)) : Array(Int32)
      data = [] of Int32
      prev_line = 0
      prev_char = 0

      tokens.each do |tok|
        delta_line = tok.line - prev_line
        delta_start = (delta_line == 0) ? (tok.character - prev_char) : tok.character

        data << delta_line
        data << delta_start
        data << tok.length
        data << tok.token_type
        data << tok.token_modifiers

        prev_line = tok.line
        prev_char = tok.character
      end

      data
    end
  end

  class TokenVisitor < Crystal::Visitor
    def initialize(@lines : Array(String), @tokens : Array(SemanticTokens::RawToken))
    end

    def visit(node : Crystal::ClassDef)
      add_name_token(node.name, 1, 1) # class, declaration
      node.body.accept(self)
      false
    end

    def visit(node : Crystal::ModuleDef)
      add_name_token(node.name, 4, 1) # interface, declaration
      node.body.accept(self)
      false
    end

    def visit(node : Crystal::EnumDef)
      add_name_token(node.name, 3, 1) # enum, declaration
      node.members.each do |member|
        add_node_token(member, 6, 1) # variable, declaration
      end
      false
    end

    def visit(node : Crystal::Alias)
      add_name_token(node.name, 0, 1) # type, declaration
      node.value.accept(self)
      false
    end

    def visit(node : Crystal::Def)
      loc = node.name_location || node.location
      add_location_token(loc, node.name.size, 9, 1) if loc # method, declaration
      node.args.each(&.accept(self))
      node.body.accept(self)
      false
    end

    def visit(node : Crystal::Macro)
      loc = node.name_location || node.location
      add_location_token(loc, node.name.size, 10, 1) if loc # macro, declaration
      node.args.each(&.accept(self))
      node.body.accept(self)
      false
    end

    def visit(node : Crystal::Arg)
      add_node_token(node, 5, 1, node.name.size) # parameter, declaration
      node.default_value.try(&.accept(self))
      false
    end

    def visit(node : Crystal::Var)
      add_node_token(node, 6, 0, node.name.size) # variable
      true
    end

    def visit(node : Crystal::InstanceVar)
      add_node_token(node, 7, 0, node.name.size) # property
      true
    end

    def visit(node : Crystal::ClassVar)
      add_node_token(node, 7, 8, node.name.size) # property, static
      true
    end

    def visit(node : Crystal::Call)
      loc = node.name_location || node.location
      add_location_token(loc, node.name.size, 9, 0) if loc # method
      node.obj.try(&.accept(self))
      node.args.each(&.accept(self))
      node.block.try(&.accept(self))
      node.named_args.try(&.each(&.value.accept(self)))
      false
    end

    def visit(node : Crystal::Path)
      name = node.names.last?
      length = name ? name.size : 1
      add_node_token(node, 0, 0, length) # type
      true
    end

    def visit(node : Crystal::NumberLiteral)
      add_node_token(node, 14, 0) # number
      true
    end

    def visit(node : Crystal::StringLiteral)
      add_node_token(node, 13, 0) # string
      true
    end

    def visit(node : Crystal::ASTNode)
      true
    end

    private def add_name_token(name_node : Crystal::ASTNode, token_type : Int32, token_modifiers : Int32)
      loc = name_node.location
      return unless loc

      length = if name_node.is_a?(Crystal::Path) && (last_name = name_node.names.last?)
                 last_name.size
               elsif name_node.responds_to?(:name)
                 name_node.name.to_s.size
               else
                 name_node.to_s.size
               end

      add_location_token(loc, length, token_type, token_modifiers)
    end

    private def add_node_token(
      node : Crystal::ASTNode,
      token_type : Int32,
      token_modifiers : Int32,
      explicit_length : Int32? = nil,
    )
      loc = node.location
      return unless loc

      length = explicit_length || node.to_s.size
      add_location_token(loc, length, token_type, token_modifiers)
    end

    private def add_location_token(
      loc : Crystal::Location,
      length : Int32,
      token_type : Int32,
      token_modifiers : Int32,
    )
      line_idx = loc.line_number - 1
      line_str = @lines[line_idx]?
      return unless line_str

      char_idx = loc.column_number - 1
      return if char_idx < 0 || char_idx >= line_str.size

      start_char = PositionUtils.char_to_utf16_index(line_str, char_idx)
      end_char = PositionUtils.char_to_utf16_index(line_str, char_idx + length)
      utf16_len = end_char - start_char

      @tokens << SemanticTokens::RawToken.new(
        line: line_idx,
        character: start_char,
        length: utf16_len,
        token_type: token_type,
        token_modifiers: token_modifiers
      )
    end
  end
end
