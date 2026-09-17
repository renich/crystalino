require "json"
require "lsp/server"

module LSP
  macro finished
    class RequestMessage(Result)
      json_discriminator "method", {
        initialize:                       InitializeRequest,
        shutdown:                         ShutdownRequest,
        "window/showMessageRequest":      ShowMessageRequest,
        "window/workDoneProgress/create": WorkDoneProgressCreateRequest,
        "textDocument/willSaveWaitUntil": WillSaveWaitUntilRequest,
        "textDocument/completion":        CompletionRequest,
        "textDocument/formatting":        DocumentFormattingRequest,
        "textDocument/rangeFormatting":   DocumentRangeFormattingRequest,
        "textDocument/hover":             HoverRequest,
        "textDocument/definition":        DefinitionRequest,
        "textDocument/signatureHelp":     SignatureHelpRequest,
        "textDocument/documentSymbol":    DocumentSymbolsRequest,
        "workspace/symbol":               WorkspaceSymbolRequest,
        "textDocument/documentHighlight": DocumentHighlightRequest,
        "textDocument/foldingRange":      FoldingRangeRequest,
        "textDocument/selectionRange":    SelectionRangeRequest,
      }, default: UnknownRequest
    end
  end
end
