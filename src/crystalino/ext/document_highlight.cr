require "json"
require "lsp/server"

module LSP
  # A document highlight kind.
  Enum.number DocumentHighlightKind do
    # A textual occurrence.
    Text = 1

    # Read-access of a symbol, like reading a variable.
    Read = 2

    # Write-access of a symbol, like writing to a variable.
    Write = 3
  end

  # A document highlight is a range inside a text document which deserves
  # special attention. Usually a document highlight is visualized by changing
  # the background color of its range.
  struct DocumentHighlight
    include Initializer
    include JSON::Serializable

    # The range this highlight applies to.
    property range : Range

    # The highlight kind, default is a text marker.
    property kind : DocumentHighlightKind?
  end

  struct DocumentHighlightParams
    include TextDocumentPositionParams
    include WorkDoneProgressParams
    include PartialResultParams
    include Initializer
    include JSON::Serializable
  end

  # The document highlight request is sent from the client to the server to
  # resolve document highlights for a given text document position.
  class DocumentHighlightRequest < RequestMessage(Array(DocumentHighlight)?)
    @method = "textDocument/documentHighlight"
    property params : DocumentHighlightParams
  end
end
