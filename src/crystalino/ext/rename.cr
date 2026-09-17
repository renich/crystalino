require "json"
require "lsp/server"

module LSP
  struct PrepareRenameParams
    include TextDocumentPositionParams
    include WorkDoneProgressParams
    include Initializer
    include JSON::Serializable
  end

  struct PrepareRenameResult
    include Initializer
    include JSON::Serializable

    property range : Range
    property placeholder : String
  end

  class PrepareRenameRequest < RequestMessage(PrepareRenameResult?)
    @method = "textDocument/prepareRename"
    property params : PrepareRenameParams
  end

  struct RenameParams
    include TextDocumentPositionParams
    include WorkDoneProgressParams
    include Initializer
    include JSON::Serializable

    @[JSON::Field(key: "newName")]
    property new_name : String
  end

  class RenameRequest < RequestMessage(WorkspaceEdit?)
    @method = "textDocument/rename"
    property params : RenameParams
  end
end
