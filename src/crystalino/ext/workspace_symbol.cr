require "json"
require "lsp/server"

module LSP
  struct WorkspaceSymbolParams
    include WorkDoneProgressParams
    include PartialResultParams
    include Initializer
    include JSON::Serializable

    # A query string to filter symbols by. Clients may send an empty
    # string here to request all symbols.
    property query : String
  end

  # The workspace symbol request is sent from the client to the server to
  # list project-wide symbols matching the query string.
  class WorkspaceSymbolRequest < RequestMessage(Array(SymbolInformation)?)
    @method = "workspace/symbol"
    property params : WorkspaceSymbolParams
  end
end
