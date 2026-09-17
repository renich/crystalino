require "json"
require "lsp/server"

module LSP
  # A selection range represents a part of a selection hierarchy. A selection range
  # may have a parent selection range that contains it.
  class SelectionRange
    include Initializer
    include JSON::Serializable

    # The range of this selection range.
    property range : Range

    # The parent selection range containing this range.
    property parent : SelectionRange?
  end

  struct SelectionRangeParams
    include WorkDoneProgressParams
    include PartialResultParams
    include Initializer
    include JSON::Serializable

    @[JSON::Field(key: "textDocument")]
    property text_document : TextDocumentIdentifier

    # The positions inside the text document.
    property positions : Array(Position)
  end

  # A request to provide selection ranges in a document.
  class SelectionRangeRequest < RequestMessage(Array(SelectionRange)?)
    @method = "textDocument/selectionRange"
    property params : SelectionRangeParams
  end
end
