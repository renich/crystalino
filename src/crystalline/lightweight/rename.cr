require "lsp/server"
require "compiler/crystal/syntax"
require "../position_utils"
require "../source_mask"
require "./resolver"
require "./document_highlight"

module Crystalline::Lightweight
  class Rename
    KEYWORDS = {
      "abstract", "alias", "annotation", "as", "as?", "asm", "begin", "break",
      "case", "class", "def", "do", "else", "elsif", "end", "ensure", "enum",
      "extend", "false", "for", "fun", "if", "in", "include", "instance_sizeof",
      "is_a?", "lib", "macro", "module", "next", "nil", "nil?", "offsetof",
      "out", "pointerof", "private", "protected", "rescue", "responds_to?",
      "return", "select", "self", "sizeof", "struct", "super", "then", "true",
      "typeof", "uninitialized", "union", "unless", "until", "verbatim", "when",
      "while", "with", "yield",
    }

    def self.prepare_rename(source : String, line_number : Int32, column_number : Int32) : LSP::PrepareRenameResult?
      new(source, line_number, column_number).prepare_rename
    end

    def self.rename(
      source : String,
      file_uri : URI,
      line_number : Int32,
      column_number : Int32,
      new_name : String,
    ) : LSP::WorkspaceEdit?
      new(source, line_number, column_number).rename(file_uri, new_name)
    end

    def initialize(@source : String, @line_number : Int32, @column_number : Int32)
      @lines = @source.lines(chomp: false)
    end

    def prepare_rename : LSP::PrepareRenameResult?
      line = @lines[@line_number]?
      return unless line

      span = Resolver.token_span(line, @column_number)
      return unless span

      start_idx, end_idx = span
      return if SourceMask.new(@source).comment_or_string?(@line_number, start_idx)

      token = line[start_idx...end_idx]?
      return if token.nil? || token.empty? || KEYWORDS.includes?(token)

      start_char = PositionUtils.char_to_utf16_index(line, start_idx)
      end_char = PositionUtils.char_to_utf16_index(line, end_idx)
      range = LSP::Range.new(
        start: LSP::Position.new(line: @line_number, character: start_char),
        end: LSP::Position.new(line: @line_number, character: end_char)
      )

      LSP::PrepareRenameResult.new(range: range, placeholder: token)
    end

    def rename(file_uri : URI, new_name : String) : LSP::WorkspaceEdit?
      prepare = prepare_rename
      return unless prepare

      target_token = prepare.placeholder
      formatted_name = sanitize_new_name(target_token, new_name)
      return unless formatted_name

      highlights = DocumentHighlight.highlights(@source, @line_number, @column_number)
      return if highlights.nil? || highlights.empty?

      text_edits = highlights.map do |highlight|
        LSP::TextEdit.new(range: highlight.range, new_text: formatted_name)
      end

      LSP::WorkspaceEdit.new(changes: {file_uri.to_s => text_edits})
    end

    private def sanitize_new_name(target_token : String, new_name : String) : String?
      name = new_name.strip
      return if name.empty?

      if target_token.starts_with?("@@")
        sanitize_cvar_name(name)
      elsif target_token.starts_with?('@')
        sanitize_ivar_name(name)
      elsif target_token =~ /\A[A-Z]/
        sanitize_const_name(name)
      else
        sanitize_ident_name(name)
      end
    end

    private def sanitize_cvar_name(name : String) : String?
      name = "@@" + name.lchop("@@")
      name =~ /\A@@[a-zA-Z_][a-zA-Z0-9_?!]*\z/ ? name : nil
    end

    private def sanitize_ivar_name(name : String) : String?
      name = "@" + name.lchop('@')
      name =~ /\A@[a-zA-Z_][a-zA-Z0-9_?!]*\z/ ? name : nil
    end

    private def sanitize_const_name(name : String) : String?
      name =~ /\A[A-Z][a-zA-Z0-9_]*\z/ ? name : nil
    end

    private def sanitize_ident_name(name : String) : String?
      name =~ /\A[a-zA-Z_][a-zA-Z0-9_?!]*\z/ ? name : nil
    end
  end
end
