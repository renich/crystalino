require "./workspace"

class Crystalline::Controller
  # The project workspace.
  getter! workspace : Workspace
  # A list of requests that are pending, used when receiving a cancel request.
  @pending_requests : Set(LSP::RequestMessage::RequestId) = Set(LSP::RequestMessage::RequestId).new
  # Used to process certain requests synchronously.
  @documents_lock = Mutex.new

  def initialize(@server : LSP::Server)
    @server.start(self)
  end

  def on_init(init_params : LSP::InitializeParams) : Nil
    @workspace = Workspace.new(@server, init_params.root_uri)
  end

  def when_ready : Nil
    spawn do
      # Ensure the disk-cached stdlib index is available for single-file
      # queries issued before the project index exists: instant on cache
      # hits, generated in the background on the first run.
      Crystalline::Lightweight::PreludeIndex.ensure_loaded

      # Then run the top-level semantic pass per project: it populates the
      # lightweight project index (including the stdlib) within seconds, so
      # interactive features work before the full compile finishes.
      workspace.projects.each do |project|
        workspace.recalculate_dependencies(@server, project)
      end

      # Then compile each project entry point at once.
      workspace.projects.each do |project|
        if entry_point = project.entry_point?
          LSP::Log.info { "[compile] startup: #{entry_point.decoded_path}" }
          workspace.compile(@server, entry_point, wants_doc: true)
        end
      end
    end
  end

  # The compiler unfortunately prevents declaring the following signature for the time being:
  # def on_request(message : LSP::RequestMessage(T)) : T forall T
  def on_request(message : LSP::RequestMessage)
    @pending_requests << message.id
    dispatch_request(message)
  rescue e : Crystal::TypeException
    LSP::Log.warn(exception: e) { e.to_s }
    nil
  rescue e : Crystal::SyntaxException
    LSP::Log.warn(exception: e) { e.to_s }
    nil
  ensure
    @pending_requests.delete message.id
  end

  private def dispatch_request(message : LSP::RequestMessage)
    case message
    when LSP::DocumentFormattingRequest
      handle_formatting_request(message)
    when LSP::DocumentRangeFormattingRequest
      handle_range_formatting_request(message)
    when LSP::HoverRequest
      handle_hover_request(message)
    when LSP::DefinitionRequest
      handle_definition_request(message)
    else
      dispatch_feature_request(message)
    end
  end

  private def dispatch_feature_request(message : LSP::RequestMessage)
    case message
    when LSP::CompletionRequest
      handle_completion_request(message)
    when LSP::DocumentSymbolsRequest
      handle_document_symbols_request(message)
    when LSP::WorkspaceSymbolRequest
      handle_workspace_symbol_request(message)
    when LSP::SignatureHelpRequest
      handle_signature_help_request(message)
    when LSP::DocumentHighlightRequest
      handle_document_highlight_request(message)
    when LSP::FoldingRangeRequest
      handle_folding_range_request(message)
    else
      nil
    end
  end

  private def handle_formatting_request(message : LSP::DocumentFormattingRequest)
    @documents_lock.synchronize {
      workspace.format_document(message.params).try { |(formatted_document, document)|
        range = LSP::Range.new(
          start: LSP::Position.new(line: 0, character: 0),
          end: document.eof_position,
        )
        [
          LSP::TextEdit.new(
            range: range,
            new_text: formatted_document,
          ),
        ]
      }
    }
  end

  private def handle_range_formatting_request(message : LSP::DocumentRangeFormattingRequest)
    @documents_lock.synchronize {
      workspace.format_document(message.params).try { |(formatted_document, document)|
        [
          LSP::TextEdit.new(
            range: message.params.range,
            new_text: formatted_document,
          ),
        ]
      }
    }
  end

  def on_notification(message : LSP::NotificationMessage) : Nil
    case message
    when LSP::DidOpenNotification
      @documents_lock.synchronize {
        workspace.open_document(message.params)
      }
    when LSP::DidChangeNotification
      @documents_lock.synchronize {
        workspace.update_document(@server, message.params)
      }
    when LSP::DidCloseNotification
      @documents_lock.synchronize {
        workspace.close_document(@server, message.params)
      }
    when LSP::DidSaveNotification
      @documents_lock.synchronize {
        workspace.save_document(@server, message.params)
      }
      file_uri = message.params.text_document.uri
      spawn do
        parsed_uri = URI.parse(file_uri)
        LSP::Log.info { "[compile] save: #{parsed_uri.decoded_path}" }
        workspace.compile(
          @server,
          parsed_uri,
          discard_nil_cached_result: true,
          wants_doc: true,
        )
      end
    when LSP::CancelNotification
      @pending_requests.delete message.params.id
    end
  rescue e : Crystal::TypeException
    LSP::Log.warn(exception: e) { e.to_s }
  rescue e : Crystal::SyntaxException
    LSP::Log.warn(exception: e) { e.to_s }
  end

  def on_response(message : LSP::ResponseMessage, original_message : LSP::RequestMessage?) : Nil
    original_message.try &.on_response(message.result, message.error)
  rescue e : Crystal::TypeException
    LSP::Log.warn(exception: e) { e.to_s }
  rescue e : Crystal::SyntaxException
    LSP::Log.warn(exception: e) { e.to_s }
  end

  private def handle_hover_request(message : LSP::HoverRequest)
    return nil unless @pending_requests.includes? message.id
    file_uri = URI.parse message.params.text_document.uri
    workspace.hover(@server, file_uri, message.params.position)
  end

  private def handle_definition_request(message : LSP::DefinitionRequest)
    return nil unless @pending_requests.includes? message.id
    file_uri = URI.parse message.params.text_document.uri
    workspace.definitions(@server, file_uri, message.params.position)
  end

  private def handle_completion_request(message : LSP::CompletionRequest)
    return nil unless @pending_requests.includes? message.id
    file_uri = URI.parse message.params.text_document.uri
    workspace.completion(@server, file_uri, message.params.position, message.params.context.try &.trigger_character)
  end

  private def handle_document_symbols_request(message : LSP::DocumentSymbolsRequest)
    @documents_lock.synchronize do
      file_uri = URI.parse message.params.text_document.uri
      document_symbols = workspace.document_symbols(@server, file_uri)

      if @server.client_capabilities.text_document.try &.document_symbol.try &.hierarchical_document_symbol_support
        document_symbols
      else
        document_symbols.try &.reduce([] of LSP::SymbolInformation) { |accumulator, document_symbol|
          accumulator.concat(document_symbol.to_symbol_information_array(message.params.text_document.uri))
        }
      end
    end
  end

  private def handle_workspace_symbol_request(message : LSP::WorkspaceSymbolRequest)
    @documents_lock.synchronize do
      workspace.workspace_symbol(@server, message.params.query)
    end
  end

  private def handle_signature_help_request(message : LSP::SignatureHelpRequest)
    return nil unless @pending_requests.includes? message.id
    file_uri = URI.parse message.params.text_document.uri
    workspace.signature_help(@server, file_uri, message.params.position)
  end

  private def handle_document_highlight_request(message : LSP::DocumentHighlightRequest)
    return nil unless @pending_requests.includes? message.id
    file_uri = URI.parse message.params.text_document.uri
    @documents_lock.synchronize do
      workspace.document_highlight(@server, file_uri, message.params.position)
    end
  end

  private def handle_folding_range_request(message : LSP::FoldingRangeRequest)
    return nil unless @pending_requests.includes? message.id
    file_uri = URI.parse message.params.text_document.uri
    @documents_lock.synchronize do
      workspace.folding_range(@server, file_uri)
    end
  end
end
