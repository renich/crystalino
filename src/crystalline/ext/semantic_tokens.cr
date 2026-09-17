require "json"
require "lsp/server"

module LSP
  struct SemanticTokensLegend
    include Initializer
    include JSON::Serializable

    @[JSON::Field(key: "tokenTypes")]
    property token_types : Array(String)

    @[JSON::Field(key: "tokenModifiers")]
    property token_modifiers : Array(String)
  end

  struct SemanticTokensFullOptions
    include Initializer
    include JSON::Serializable

    property delta : Bool?
  end

  struct SemanticTokensOptions
    include Initializer
    include JSON::Serializable

    property legend : SemanticTokensLegend
    property full : (Bool | SemanticTokensFullOptions)?
    property range : Bool?
  end

  struct ServerCapabilities
    @[JSON::Field(key: "semanticTokensProvider")]
    property semantic_tokens_provider : SemanticTokensOptions?
  end

  struct SemanticTokensParams
    include WorkDoneProgressParams
    include PartialResultParams
    include Initializer
    include JSON::Serializable

    @[JSON::Field(key: "textDocument")]
    property text_document : TextDocumentIdentifier
  end

  struct SemanticTokens
    include Initializer
    include JSON::Serializable

    @[JSON::Field(key: "resultId")]
    property result_id : String?

    property data : Array(Int32)
  end

  class SemanticTokensRequest < RequestMessage(SemanticTokens?)
    @method = "textDocument/semanticTokens/full"
    property params : SemanticTokensParams
  end
end
