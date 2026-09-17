require "json"
require "lsp/server"

module LSP
  Enum.string FoldingRangeKind do
    Comment
    Imports
    Region
  end

  # Represents a folding range in a text document.
  struct FoldingRange
    include Initializer
    include JSON::Serializable

    # The zero-based line number from where the folded range starts.
    @[JSON::Field(key: "startLine")]
    property start_line : Int32

    # The zero-based character offset from where the folded range starts.
    @[JSON::Field(key: "startCharacter")]
    property start_character : Int32?

    # The zero-based line number where the folded range ends.
    @[JSON::Field(key: "endLine")]
    property end_line : Int32

    # The zero-based character offset before the folded range ends.
    @[JSON::Field(key: "endCharacter")]
    property end_character : Int32?

    # Describes the kind of the folding range such as `comment` or `region`.
    property kind : FoldingRangeKind?
  end

  struct FoldingRangeParams
    include WorkDoneProgressParams
    include PartialResultParams
    include Initializer
    include JSON::Serializable

    @[JSON::Field(key: "textDocument")]
    property text_document : TextDocumentIdentifier
  end

  # The folding range request is sent from the client to the server to return all folding ranges
  # found in a given text document.
  class FoldingRangeRequest < RequestMessage(Array(FoldingRange)?)
    @method = "textDocument/foldingRange"
    property params : FoldingRangeParams
  end
end
