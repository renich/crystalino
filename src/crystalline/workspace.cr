require "uri"
require "yaml"
require "./text_document"
require "./progress"
require "./project"
require "./result_cache"
require "./lightweight/completion"
require "./lightweight/hover"
require "./lightweight/definitions"
require "./lightweight/signature_help"
require "./analysis/*"

class Crystalline::Workspace
  # The previous compilation results, indexed by compilation entry point.
  @result_cache : Crystalline::ResultCache = Crystalline::ResultCache.new
  # Last successful semantic analysis results, used as a fast fallback for interactive features.
  # The cache survives document edits (only the compile-result dedup cache is invalidated);
  # semantic_cache_allowed? refuses to serve files that changed on disk after the compile.
  @semantic_cache : Hash(String, Crystal::Compiler::Result) = {} of String => Crystal::Compiler::Result
  # On-disk modification time of every source file at the last successful compile.
  @compiled_source_mtimes : Hash(String, Time) = {} of String => Time
  # Lightweight queries per open document, keyed by (uri, version). Each one
  # shares the project index and overlays only the document's own source, so
  # rebuilding one is cheap and must not happen per request.
  @query_cache = {} of String => {Int32, Crystalline::Lightweight::Query}
  @query_cache_lock = Mutex.new
  # Guards @opened_documents against the background query warm-up, which runs
  # on the compile execution context while the main context mutates the map.
  @documents_mutex = Mutex.new
  # The workspace filesystem uri.
  getter root_uri : URI?
  # A list of documents that are openened in the text editor.
  getter opened_documents = {} of String => TextDocument
  # A list of projects in this workspace
  getter projects = [] of Project

  def initialize(server : LSP::Server, root_uri : String?)
    if parsed_uri = root_uri.try &->URI.parse(String)
      @root_uri = parsed_uri
      @projects = Project.find_in_workspace_root parsed_uri
      if @projects.size > 0
        LSP::Log.info {
          <<-LOG
          "[workspace] Found projects:
          #{@projects.map(&.root_uri.decoded_path).join('\n')}
          LOG
        }
      end
    end
  end

  def open_document(params : LSP::DidOpenTextDocumentParams)
    raw_uri = params.text_document.uri
    uri = URI.parse(raw_uri)
    project = project_for_file(uri)
    document = TextDocument.new(uri, project, params.text_document.text)
    @documents_mutex.synchronize { @opened_documents[raw_uri] = document }
  end

  def update_document(server : LSP::Server, params : LSP::DidChangeTextDocumentParams)
    file_uri = params.text_document.uri
    parsed_uri = URI.parse(file_uri)
    document = @opened_documents[file_uri]?

    document.try { |opened_document|
      content_changes = params.content_changes.map { |change|
        {change.text, change.range}
      }
      opened_document.update_contents(content_changes, version: params.text_document.version)
    }

    @result_cache.invalidate(file_uri)
    invalidate_project_caches(parsed_uri, document)
    @query_cache_lock.synchronize { @query_cache.delete(file_uri) }
  end

  def close_document(server : LSP::Server, params : LSP::DidCloseTextDocumentParams)
    file_uri = params.text_document.uri
    parsed_uri = URI.parse(file_uri)
    document = @documents_mutex.synchronize { @opened_documents.delete(params.text_document.uri) }
    @result_cache.invalidate(file_uri)
    # The parsed source index snapshots disk state: a saved or closed file
    # may have changed on disk, so the next query rebuilds it.
    project_for_file(parsed_uri).try(&.source_index = nil)
    invalidate_project_caches(parsed_uri, document)
    @query_cache_lock.synchronize { @query_cache.delete(file_uri) }
    Diagnostics.new.init_value(file_uri).publish(server) unless document.try(&.project?)
  end

  def save_document(server : LSP::Server, params : LSP::DidSaveTextDocumentParams)
    file_uri = params.text_document.uri
    parsed_uri = URI.parse(file_uri)
    document = @opened_documents[file_uri]?

    document.try &.mark_saved
    @result_cache.invalidate(file_uri)
    # The file changed on disk: the parsed source index is stale until it
    # is rebuilt (or the compile replaces it with the semantic index).
    project_for_file(parsed_uri).try(&.source_index = nil)
    invalidate_project_caches(parsed_uri, document)
  end

  def format_document(params : LSP::DocumentFormattingParams) : {String, TextDocument}?
    @opened_documents[params.text_document.uri]?.try { |document|
      contents = document.contents
      return if contents.blank?
      formatted = Crystal.format(contents)
      # Basic safety check: if formatting returned an empty string but the original wasn't empty,
      # something went wrong. Also check for basic syntax validity of the result.
      begin
        Crystal::Parser.parse(formatted)
      rescue e
        LSP::Log.warn { "Formatting skipped for #{params.text_document.uri}: the result contains syntax errors. #{e.message}" }
        return nil
      end
      {formatted, document}
    }
  rescue e
    LSP::Log.warn { "Formatting failed for #{params.text_document.uri}: #{e.message}" }
    nil
  end

  def format_document(params : LSP::DocumentRangeFormattingParams) : {String, TextDocument}?
    @opened_documents[params.text_document.uri]?.try { |document|
      range = params.range
      contents_lines = document.contents.lines(chomp: false)[range.start.line..range.end.line]?
      return if contents_lines.nil? || contents_lines.empty?

      last_line = contents_lines.last
      end_char = Math.min(range.end.character, last_line.size)
      contents_lines[-1] = last_line[...end_char]

      first_line = contents_lines.first
      start_char = Math.min(range.start.character, first_line.size)
      contents_lines[0] = first_line[start_char...]

      target = contents_lines.join
      return if target.blank?

      formatted = Crystal.format(target)
      # For range formatting, we might not be able to parse the fragment alone,
      # but we can check if it's empty.
      # Also chomp the result because Crystal.format always adds a trailing newline.
      return if formatted.blank?

      {formatted.chomp, document}
    }
  rescue e
    LSP::Log.warn { "Range formatting failed for #{params.text_document.uri}: #{e.message}" }
    nil
  end

  # Run a top level semantic analysis to compute dependencies.
  def recalculate_dependencies(server, project)
    return unless target = project.entry_point?

    LSP::Log.info { "[compile] dependency recalculation: #{target.decoded_path}" }
    lib_path = project.default_lib_path
    Analysis.compile(server, target, lib_path: lib_path, ignore_diagnostics: true, wants_doc: true, top_level: true, compiler_flags: project.flags).try { |result|
      project.dependencies = result.program.requires
      # Build the summary and index off the event loop: they walk the whole
      # typed program. The top-level pass gives the compiler-derived method
      # restrictions and block contracts within seconds, before the full
      # compile finishes.
      summary, index = Analysis.run_dedicated do
        {
          Crystalline::Lightweight::Summary.from_result(result),
          Crystalline::Lightweight::Index.from_program(result.program),
        }
      end
      project.semantic_summary = summary
      project.lightweight_index = index
      @query_cache_lock.synchronize { @query_cache.clear }
      warm_query_cache
    }
  rescue
    nil
  end

  # Allow one compilation at a time.
  class_getter compilation_lock = Mutex.new

  # Use the crystal compiler to typecheck the program.
  def compile(
    server : LSP::Server,
    file_uri : URI,
    *,
    ignore_diagnostics = server.client_capabilities.ignore_diagnostics?,
    ignore_cached_result = false,
    wants_doc = false,
    top_level = false,
    discard_nil_cached_result = false,
  )
    @projects.each do |project|
      # If the project has less than 1 dependency, it could mean that the last
      # dependency calculation failed (likely because of a syntax error). So we
      # try again.
      recalculate_dependencies(server, project) if project.dependencies.size < 2
    end

    project = Project.best_fit_for_file(@projects, file_uri)

    # LSP::Log.info { "Compiling #{file_uri}, project: #{project.try(&.root_uri.decoded_path)}" }

    target, progress = prepare_compile_target(project, file_uri)

    target_string = target.to_s
    LSP::Log.info do
      source_kind = if top_level
                      "top-level"
                    else
                      "filesystem"
                    end
      "[compile] request: target=#{target.decoded_path} source=#{source_kind} ignore_cached=#{ignore_cached_result} discard_nil_cached=#{discard_nil_cached_result}"
    end
    hit, cached_result = check_compile_cache(target_string, target, ignore_cached_result, discard_nil_cached_result)
    return cached_result if hit

    # Wait for pending compilations to finish…
    @@compilation_lock.synchronize do
      # Check again the cache in case some previous compilation that ran while waiting for the mutex to unlock is still valid.
      hit_after, cached_result_after = check_compile_cache(target_string, target, ignore_cached_result, discard_nil_cached_result)
      return cached_result_after if hit_after

      sync_channel = Channel(Crystal::Compiler::Result?).new(1)

      progress.report(server) do
        # Store the start of the compilation.
        compilation_start = @result_cache.monotonic_now

        lib_path = project.try(&.default_lib_path)
        LSP::Log.info { "[compile] analysis start: #{target.decoded_path}" }
        result = Analysis.compile(server, target, lib_path: lib_path, ignore_diagnostics: ignore_diagnostics, wants_doc: wants_doc, top_level: top_level, compiler_flags: project.try(&.flags) || [] of String)
        # Store the result in the cache, unless a client event invalided the previous cache.
        # For instance if a compilation is running, but the user saved the document in the meantime (before completion)
        # then we discard the result because it is already outdated.
        @result_cache.set(target_string, result, unless_invalidated_since: compilation_start)

        process_compile_result(result, project, target_string, top_level)
      ensure
        sync_channel.send(result)
      end

      select
      when result = sync_channel.receive
        result
        # Just in case…
      when timeout 120.seconds
        progress.send_progress_end(server)
        nil
      end
    end
  end

  private def prepare_compile_target(project, file_uri)
    if project && (entry_point = project.entry_point?)
      target = entry_point
      progress = Progress.new(
        token: "workspace/compile",
        title: "Building project",
        message: target.decoded_path
      )
    else
      target = file_uri
      progress = Progress.new(
        token: "workspace/compile",
        title: "Building",
        message: target.decoded_path
      )
    end
    {target, progress}
  end

  private def check_compile_cache(target_string, target, ignore_cached_result, discard_nil_cached_result)
    return {false, nil} if ignore_cached_result || !@result_cache.exists?(target_string) || @result_cache.invalidated?(target_string)

    cached_result = @result_cache.get(target_string)
    LSP::Log.info { "[compile] cache hit: #{target.decoded_path}" }
    if cached_result.nil? && discard_nil_cached_result
      {false, nil}
    else
      {true, cached_result}
    end
  end

  private def process_compile_result(result, project, target_string, top_level)
    if result && !top_level && !@result_cache.invalidated?(target_string)
      summary, index = Analysis.run_dedicated do
        {
          Crystalline::Lightweight::Summary.from_result(result),
          Crystalline::Lightweight::Index.from_program(result.program),
        }
      end

      unless @result_cache.invalidated?(target_string)
        @semantic_cache[target_string] = result
        stamp_compiled_sources(result)
        project.try &.semantic_summary = summary
        project.try(&.lightweight_index=(index))
        @query_cache_lock.synchronize { @query_cache.clear }
        warm_query_cache
      end
    end

    if result
      if p = project
        if p.entry_point?
          p.dependencies = result.program.requires
        end
      end
      "Completed successfully."
    else
      "Completed with errors."
    end
  end

  private def project_for_file(file_uri : URI) : Project?
    Project.best_fit_for_file(@projects, file_uri)
  end

  private def lightweight_query_for(document : TextDocument) : Crystalline::Lightweight::Query?
    cache_key = document.uri.to_s
    @query_cache_lock.synchronize do
      if cached = @query_cache[cache_key]?
        return cached[1] if cached[0] == document.version_number
      end
    end

    query = build_lightweight_query_from_project(document)
    query ||= build_lightweight_query_from_source(document)

    @query_cache_lock.synchronize do
      if query
        @query_cache[cache_key] = {document.version_number, query}
      else
        @query_cache.delete(cache_key)
      end
    end
    query
  end

  private def build_lightweight_query_from_project(document : TextDocument) : Crystalline::Lightweight::Query?
    project = document.project? || Project.best_fit_for_file(@projects, document.uri, require_dependency: false)
    return unless project
    project_index = project.lightweight_index
    return unless project_index

    if document.dirty? || !project.dependencies.includes?(document.uri.decoded_path)
      source_index = Crystalline::Lightweight::Index.from_source(fix_source(document.contents), document.uri.decoded_path)
      Crystalline::Lightweight::Query.new(project_index, project.semantic_summary, secondary: Crystalline::Lightweight::PreludeIndex.get, overlay: source_index)
    else
      Crystalline::Lightweight::Query.new(project_index, project.semantic_summary, secondary: Crystalline::Lightweight::PreludeIndex.get)
    end
  end

  private def build_lightweight_query_from_source(document : TextDocument) : Crystalline::Lightweight::Query?
    source_index = Crystalline::Lightweight::Index.from_source(fix_source(document.contents), document.uri.decoded_path)
    return unless source_index

    project_index = document.project?.try(&.source_index) || Project.best_fit_for_file(@projects, document.uri, require_dependency: false).try(&.source_index)
    prelude = Crystalline::Lightweight::PreludeIndex.get

    if project_index
      if prelude
        Crystalline::Lightweight::Query.new(project_index, secondary: prelude, overlay: source_index)
      else
        Crystalline::Lightweight::Query.new(project_index, overlay: source_index)
      end
    elsif prelude
      Crystalline::Lightweight::Query.new(prelude, overlay: source_index)
    else
      Crystalline::Lightweight::Query.new(source_index)
    end
  end

  # Rebuild the cached lightweight query of every opened document in the
  # background, so the first interactive request after a compile does not pay
  # the project-index merge. Runs on the compile context: snapshot the open
  # documents under a lock before touching them.
  private def warm_query_cache
    spawn do
      documents = @documents_mutex.synchronize { @opened_documents.values.dup }
      documents.each do |document|
        lightweight_query_for(document)
      end
    end
  end

  private def semantic_cache_key(file_uri : URI) : String
    if (project = project_for_file(file_uri)) && (entry_point = project.entry_point?)
      entry_point.to_s
    else
      file_uri.to_s
    end
  end

  private def invalidate_project_caches(file_uri : URI, document : TextDocument?)
    cache_keys = Set(String).new

    document.try(&.project?).try(&.entry_point?).try { |entry|
      cache_keys << entry.to_s
    }

    project_for_file(file_uri).try(&.entry_point?).try { |entry|
      cache_keys << entry.to_s
    }

    # The semantic cache is intentionally kept across edits: it holds the
    # last successful compile and semantic_cache_allowed? refuses to serve
    # it for files that changed since.
    cache_keys.each do |cache_key|
      @result_cache.invalidate(cache_key)
    end
  end

  private def semantic_cache_allowed?(file_uri : URI) : Bool
    document = @opened_documents[file_uri.to_s]?
    return false if document.try(&.dirty?)

    # The semantic cache holds the last successful compile. Only serve it
    # for files whose on-disk content is the one that was compiled, so a
    # save whose compile failed (or an external edit) cannot poison other
    # files' requests with stale results.
    return true unless file_uri.scheme == "file"

    path = file_uri.decoded_path
    mtime = @compiled_source_mtimes[path]?
    return true unless mtime

    File.info(path).modification_time == mtime
  rescue File::NotFoundError
    false
  end

  private def stamp_compiled_sources(result : Crystal::Compiler::Result)
    stamps = {} of String => Time
    result.program.requires.each do |filename|
      begin
        stamps[filename] = File.info(filename).modification_time
      rescue File::NotFoundError
      end
    end
    @compiled_source_mtimes = stamps
  end

  private def append_markdown_doc(contents : Array(String), doc : String?)
    if doc
      contents << "----------"
      contents << <<-MARKDOWN
      #{doc}
      MARKDOWN
    end
  end

  private def code_markdown(str : String?, *, language = "") : String
    if str
      <<-MARKDOWN
      ```#{language}
      #{str}
      ```
      MARKDOWN
    else
      ""
    end
  end

  def hover(server : LSP::Server, file_uri : URI, position : LSP::Position)
    if text_document = @opened_documents[file_uri.to_s]?
      source = fix_source(text_document.contents)
      if query = lightweight_query_for(text_document)
        hover, reason = Crystalline::Lightweight::Hover.hover_and_reason(source, position.line, position.character, query)
        if hover
          LSP::Log.info { "[hover] lightweight hit: #{file_uri.decoded_path}:#{position.line}:#{position.character}" }
          return hover
        end

        LSP::Log.info { "[hover] lightweight miss: #{file_uri.decoded_path}:#{position.line}:#{position.character} reason=#{reason}" }
      else
        LSP::Log.info { "[hover] lightweight miss: #{file_uri.decoded_path}:#{position.line}:#{position.character} reason=no lightweight query" }
      end
    end

    unless semantic_cache_allowed?(file_uri)
      LSP::Log.info { "[hover] bail on dirty buffer: #{file_uri.decoded_path}:#{position.line}:#{position.character}" }
      return
    end

    result = @semantic_cache[semantic_cache_key(file_uri)]?
    unless result
      LSP::Log.info { "[hover] bail without compile: #{file_uri.decoded_path}:#{position.line}:#{position.character}" }
      return
    end

    LSP::Log.info { "[hover] semantic cache hit: #{file_uri.decoded_path}:#{position.line}:#{position.character}" }
    location = Crystal::Location.new(
      file_uri.decoded_path,
      line_number: position.line + 1,
      column_number: position.character + 1
    )
    result.try { |res|
      Analysis.nodes_at_cursor(res, location)
    }.try do |nodes, _context|
      node = nodes.last?
      contents = build_hover_contents(node, nodes)
      LSP::Hover.new(
        contents: LSP::MarkupContent.new(
          kind: LSP::MarkupKind::MarkDown,
          value: contents.join "\n",
        ),
      )
    end
  rescue
    nil
  end

  def signature_help(server : LSP::Server, file_uri : URI, position : LSP::Position) : LSP::SignatureHelp?
    if text_document = @opened_documents[file_uri.to_s]?
      if query = lightweight_query_for(text_document)
        sig_help = Crystalline::Lightweight::SignatureHelp.signature_help(text_document.contents, position.line, position.character, query)
        if sig_help
          LSP::Log.info { "[signature_help] hit: #{file_uri.decoded_path}:#{position.line}:#{position.character}" }
          return sig_help
        end
        LSP::Log.info { "[signature_help] miss: #{file_uri.decoded_path}:#{position.line}:#{position.character}" }
      end
    end
    nil
  end

  private def build_hover_contents(node, nodes) : Array(String)
    contents = [] of String

    if node.is_a? Crystal::Def || node.is_a? Crystal::Macro
      build_def_macro_hover(node, contents)
    elsif (node.is_a? Crystal::MacroExpression || node.is_a? Crystal::MacroIf) && node.expanded
      contents << code_markdown(node.expanded.to_s, language: "crystal")
    elsif node.responds_to? :resolved_type
      build_resolved_type_hover(node, contents)
    elsif node.is_a? Crystal::Call
      build_call_hover(node, contents)
    elsif node.is_a? Crystal::Path
      build_path_hover(node, nodes, contents)
    elsif node
      build_generic_node_hover(node, contents)
    end

    contents
  end

  private def build_def_macro_hover(node, contents)
    contents << code_markdown(Utils.format_def(node), language: "crystal")
    append_markdown_doc contents, node.doc
  end

  private def build_resolved_type_hover(node, contents)
    str = ""
    if node.responds_to? :name
      str += "#{node.name}: #{node.resolved_type}"
    else
      str += node.resolved_type.to_s
      str = node.to_s if str.empty?
    end
    contents << code_markdown(str, language: "crystal")
    append_markdown_doc contents, node.resolved_type.doc
  end

  private def build_call_hover(node, contents)
    if definition = node.target_defs.try &.first?
      contents << code_markdown(Utils.format_def(definition), language: "crystal")
    elsif node.expanded && node.expanded_macro
      contents << code_markdown(node.expanded.to_s, language: "crystal")
    end
    append_markdown_doc contents, (definition || node.expanded_macro).try &.doc
  end

  private def build_path_hover(node, nodes, contents)
    node_type = node.type? || Utils.resolve_path(node, nodes)
    if node_type
      contents << code_markdown(node_type.to_s, language: "crystal")
      append_markdown_doc contents, node_type.doc
    end
  end

  private def build_generic_node_hover(node, contents)
    str = ""
    if node.responds_to? :name
      str += "#{node.name}: #{node.type? || "?"}"
    else
      str += node.type?.to_s
      str = node.to_s if str.empty?
    end
    contents << code_markdown(str, language: "crystal")
    append_markdown_doc contents, node.doc
  end

  def definitions(server : LSP::Server, file_uri : URI, position : LSP::Position)
    if text_document = @opened_documents[file_uri.to_s]?
      source = fix_source(text_document.contents)
      query = lightweight_query_for(text_document)
      locations, reason = Crystalline::Lightweight::Definitions.definitions_and_reason(source, file_uri, position.line, position.character, query)
      if locations
        LSP::Log.info { "[definitions] lightweight hit: #{file_uri.decoded_path}:#{position.line}:#{position.character}" }
        return locations
      end

      LSP::Log.info { "[definitions] lightweight miss: #{file_uri.decoded_path}:#{position.line}:#{position.character} reason=#{reason}" }
    end

    unless semantic_cache_allowed?(file_uri)
      LSP::Log.info { "[definitions] bail on dirty buffer: #{file_uri.decoded_path}:#{position.line}:#{position.character}" }
      return
    end

    result = @semantic_cache[semantic_cache_key(file_uri)]?
    unless result
      LSP::Log.info { "[definitions] bail without compile: #{file_uri.decoded_path}:#{position.line}:#{position.character}" }
      return
    end

    LSP::Log.info { "[definitions] semantic cache hit: #{file_uri.decoded_path}:#{position.line}:#{position.character}" }

    location = Crystal::Location.new(
      file_uri.decoded_path,
      line_number: position.line + 1,
      column_number: position.character + 1
    )
    result.try { |res|
      Analysis.definitions_at_cursor(res, location)
    }.try do |definitions|
      node = definitions.node
      definitions.locations.try &.compact_map { |start_loc, end_loc|
        if node.is_a?(Crystal::Path) || node.is_a?(Crystal::Require)
          origin_location = node.location
          next unless origin_location

          target_uri = "file://#{start_loc.original_filename}"
          origin_end_location = definitions.node.end_location || Crystal::Location.new(
            file_uri.decoded_path,
            line_number: origin_location.line_number + 1,
            column_number: 0
          )

          origin_selection_range = LSP::Range.new(
            start: LSP::Position.new(line: origin_location.line_number - 1, character: origin_location.column_number - 1),
            end: LSP::Position.new(line: origin_end_location.line_number - 1, character: origin_end_location.column_number),
          )
          target_range = LSP::Range.new(
            start: LSP::Position.new(line: start_loc.line_number - 1, character: start_loc.column_number - 1),
            end: LSP::Position.new(line: end_loc.line_number - 1, character: end_loc.column_number),
          )

          LSP::LocationLink.new(
            target_uri: target_uri,
            origin_selection_range: origin_selection_range,
            target_range: target_range,
            target_selection_range: target_range,
          )
        else
          LSP::Location.new(
            uri: "file://#{start_loc.original_filename}",
            range: LSP::Range.new(
              start: LSP::Position.new(line: start_loc.line_number - 1, character: start_loc.column_number - 1),
              end: LSP::Position.new(line: end_loc.line_number - 1, character: end_loc.column_number),
            ),
          )
        end
      }
    end
  rescue
    nil
  end

  def completion(server : LSP::Server, file_uri : URI, position : LSP::Position, trigger_character : String?) : LSP::CompletionList?
    text_document = @opened_documents[file_uri.to_s]?
    return unless text_document

    document_lines = fix_source(text_document.contents).lines(chomp: false)
    completion_context = CompletionContext.detect(document_lines[position.line], position.character, trigger_character)
    return unless completion_context

    trigger_character = completion_context.trigger_character

    if query = lightweight_query_for(text_document)
      completion_items, reason = Crystalline::Lightweight::Completion.complete_and_reason(document_lines.join, position.line, completion_context, query)
      if completion_items
        # A resolved completion may legitimately be empty (e.g. no ivars
        # match a fragment): only a miss (nil) falls through to the
        # compiled fallback.
        LSP::Log.info { "[completion] lightweight hit: #{file_uri.decoded_path}:#{position.line}:#{position.character} items=#{completion_items.size}" }
        return build_completion_list(completion_items)
      end

      LSP::Log.info { "[completion] lightweight miss: #{file_uri.decoded_path}:#{position.line}:#{position.character} reason=#{reason}" }
    else
      LSP::Log.info { "[completion] lightweight miss: #{file_uri.decoded_path}:#{position.line}:#{position.character} reason=no lightweight query" }
    end

    location = Crystal::Location.new(
      file_uri.decoded_path,
      line_number: position.line + 1,
      column_number: completion_context.analysis_column,
    )

    unless semantic_cache_allowed?(file_uri)
      LSP::Log.info { "[completion] bail on dirty buffer: #{file_uri.decoded_path}:#{position.line}:#{position.character}" }
      return
    end

    result = @semantic_cache[semantic_cache_key(file_uri)]?
    unless result
      LSP::Log.info { "[completion] bail without compile: #{file_uri.decoded_path}:#{position.line}:#{position.character}" }
      return
    end

    LSP::Log.info { "[completion] semantic cache hit: #{file_uri.decoded_path}:#{position.line}:#{position.character}" }

    nodes, _ = Analysis.nodes_at_cursor(result, location)
    nodes.last?.try do |node|
      completion_items = [] of LSP::CompletionItem

      # LSP::Log.info { "Node at cursor: #{n}" }
      # LSP::Log.info { "Node class: #{n.class}" }
      # LSP::Log.info { "Node type: #{n.type?}" }
      # LSP::Log.info { "Node type class: #{n.type?.try &.class}" }
      # LSP::Log.info { "Node type defs: #{n.type?.try &.defs}" }

      range = completion_context.completion_range(position.line)

      add_completion_items(node, nodes, range, trigger_character, result, location, completion_items)

      build_completion_list(completion_items)
    end
  rescue
    nil
  end

  private def build_completion_list(completion_items : Array(LSP::CompletionItem)) : LSP::CompletionList
    selected_element_index = nil
    completion_items.each_with_index do |elt, i|
      sort_text = elt.sort_text || elt.label
      selected_element_index ||= i
      target = completion_items[selected_element_index].try { |e| e.sort_text || e.label }
      if (sort_text <=> target) < 0
        selected_element_index = i
      end
    end

    if selected_element_index
      selected_element = completion_items[selected_element_index]
      selected_element.preselect = true
      completion_items[selected_element_index] = selected_element
    end

    LSP::CompletionList.new(
      is_incomplete: false,
      items: completion_items,
    )
  end

  def document_symbols(server : LSP::Server, file_uri : URI)
    @opened_documents[file_uri.to_s]?.try { |text_document|
      parser = Crystal::Parser.new(fix_source(text_document.contents))
      parser.filename = file_uri.decoded_path
      parser.wants_doc = false

      Analysis::DocumentSymbolsVisitor.new.tap { |visitor|
        parser.parse.accept(visitor)
      }.symbols
    }
  end

  def document_highlight(server : LSP::Server, file_uri : URI, position : LSP::Position) : Array(LSP::DocumentHighlight)?
    source = if text_document = @opened_documents[file_uri.to_s]?
               fix_source(text_document.contents)
             elsif File.exists?(file_uri.decoded_path)
               File.read(file_uri.decoded_path)
             end
    return unless source

    Crystalline::Lightweight::DocumentHighlight.highlights(source, position.line, position.character)
  end

  def folding_range(server : LSP::Server, file_uri : URI) : Array(LSP::FoldingRange)?
    source = if text_document = @opened_documents[file_uri.to_s]?
               fix_source(text_document.contents)
             elsif File.exists?(file_uri.decoded_path)
               File.read(file_uri.decoded_path)
             end
    return unless source

    Crystalline::Lightweight::FoldingRange.folding_ranges(source)
  end

  def selection_range(server : LSP::Server, file_uri : URI, positions : Array(LSP::Position)) : Array(LSP::SelectionRange)?
    source = if text_document = @opened_documents[file_uri.to_s]?
               fix_source(text_document.contents)
             elsif File.exists?(file_uri.decoded_path)
               File.read(file_uri.decoded_path)
             end
    return unless source

    Crystalline::Lightweight::SelectionRange.selection_ranges(source, positions)
  end

  def semantic_tokens(server : LSP::Server, file_uri : URI) : LSP::SemanticTokens?
    source = if text_document = @opened_documents[file_uri.to_s]?
               fix_source(text_document.contents)
             elsif File.exists?(file_uri.decoded_path)
               File.read(file_uri.decoded_path)
             end
    return unless source

    Crystalline::Lightweight::SemanticTokens.tokens(source)
  end

  def prepare_rename(server : LSP::Server, file_uri : URI, position : LSP::Position) : LSP::PrepareRenameResult?
    source = if text_document = @opened_documents[file_uri.to_s]?
               fix_source(text_document.contents)
             elsif File.exists?(file_uri.decoded_path)
               File.read(file_uri.decoded_path)
             end
    return unless source

    Crystalline::Lightweight::Rename.prepare_rename(source, position.line, position.character)
  end

  def rename(server : LSP::Server, file_uri : URI, position : LSP::Position, new_name : String) : LSP::WorkspaceEdit?
    source = if text_document = @opened_documents[file_uri.to_s]?
               fix_source(text_document.contents)
             elsif File.exists?(file_uri.decoded_path)
               File.read(file_uri.decoded_path)
             end
    return unless source

    Crystalline::Lightweight::Rename.rename(source, file_uri, position.line, position.character, new_name)
  end

  def workspace_symbol(server : LSP::Server, query : String) : Array(LSP::SymbolInformation)
    symbols = [] of LSP::SymbolInformation
    query = query.downcase

    @projects.each do |project|
      if index = project.lightweight_index
        index.types.each_value do |type|
          collect_workspace_type(type, query, symbols)
          type.methods.each do |method|
            collect_workspace_method(method, query, symbols, type.name)
          end
        end

        index.top_level_methods.each do |method|
          collect_workspace_method(method, query, symbols, nil)
        end
      end
    end

    symbols.first(100)
  end

  private def add_completion_items(node, nodes, range, trigger_character, result, location, completion_items)
    case trigger_character
    when "."
      add_method_completions(node, range, completion_items)
    when ":"
      add_module_completions(node, nodes, range, trigger_character, result, completion_items)
    else
      add_context_completions(range, trigger_character, result, location, completion_items)
    end
  end

  private def add_method_completions(node, range, completion_items)
    node_type = node.type?
    node_type = node_type.base_type if node_type.responds_to? :base_type

    if node_type && node_type.responds_to?(:defs)
      Analysis.all_defs(node_type).each { |def_name, definition, owner_type, nesting|
        owner_prefix = "*Inherited from: #{owner_type.name}*\n\n" if owner_type.responds_to? :name && owner_type != node.type
        owner_prefix ||= ""
        documentation = (owner_prefix + (definition.doc || ""))

        completion_items << LSP::CompletionItem.new(
          label: Utils.format_def(definition, short: true),
          insert_text: def_name,
          kind: LSP::CompletionItemKind::Function,
          filter_text: def_name,
          detail: Utils.format_def(definition),
          text_edit: LSP::TextEdit.new(range: range, new_text: def_name),
          sort_text: (nesting + 1).chr.to_s + def_name,
          documentation: documentation.try { |doc| LSP::MarkupContent.new(kind: LSP::MarkupKind::MarkDown, value: doc) },
        )
      }

      Analysis.all_macros(node.type).each { |macro_name, macro_def, owner_type, nesting|
        owner_prefix = "*Inherited from: #{owner_type.name}*\n\n" if owner_type.responds_to? :name && owner_type != node.type
        owner_prefix ||= ""
        documentation = (owner_prefix + (macro_def.doc || ""))

        completion_items << LSP::CompletionItem.new(
          label: Utils.format_def(macro_def, short: true),
          insert_text: macro_name,
          kind: LSP::CompletionItemKind::Method,
          filter_text: macro_name,
          detail: Utils.format_def(macro_def),
          text_edit: LSP::TextEdit.new(range: range, new_text: macro_name),
          sort_text: (nesting + 1).chr.to_s + macro_name,
          documentation: documentation.try { |doc| LSP::MarkupContent.new(kind: LSP::MarkupKind::MarkDown, value: doc) },
        )
      }
    end
  end

  private def add_module_completions(node, nodes, range, trigger_character, result, completion_items)
    node_type = node.type?
    node_type ||= Utils.resolve_path(node, nodes) if node.is_a? Crystal::Path

    if node_type.is_a? Crystal::MetaclassType
      node_type = node_type.instance_type
      Analysis.all_submodules(result, node_type).uniq(&.to_s).each { |type|
        type_string = type.to_s
        completion_items << LSP::CompletionItem.new(
          label: type_string,
          text_edit: LSP::TextEdit.new(range: range, new_text: type_string.lchop(node_type.to_s).lchop(trigger_character || ':')),
          kind: Crystalline::Utils.map_completion_kind(type, default: LSP::CompletionItemKind::Module),
          documentation: type.doc.try { |doc| LSP::MarkupContent.new(kind: LSP::MarkupKind::MarkDown, value: doc) },
        )
      }
    end
  end

  private def add_context_completions(range, trigger_character, result, location, completion_items)
    context = Analysis.context_at(result, location)
    context.try &.select!(&.starts_with?("@")) if trigger_character == "@"

    context.try &.each { |name, type|
      completion_items << LSP::CompletionItem.new(
        label: "#{name} : #{type}",
        text_edit: LSP::TextEdit.new(range: range, new_text: name.lchop(trigger_character || "")),
        kind: LSP::CompletionItemKind::Variable,
        documentation: type.doc.try { |doc| LSP::MarkupContent.new(kind: LSP::MarkupKind::MarkDown, value: doc) },
      )
    }
  end

  private def collect_workspace_type(type, query, symbols)
    type_name = type.name
    return unless query.empty? || type_name.downcase.includes?(query)

    if loc = type.name_location || type.location
      symbols << LSP::SymbolInformation.new(
        name: type_name,
        kind: LSP::SymbolKind::Class,
        deprecated: false,
        location: LSP::Location.new(
          uri: "file://#{loc.filename}",
          range: LSP::Range.new(
            start: LSP::Position.new(line: loc.line_number - 1, character: loc.column_number - 1),
            end: LSP::Position.new(line: loc.line_number - 1, character: loc.column_number - 1)
          )
        ),
        container_name: nil
      )
    end
  end

  private def collect_workspace_method(method, query, symbols, container_name)
    return unless query.empty? || method.name.downcase.includes?(query)

    if loc = method.name_location || method.location
      symbols << LSP::SymbolInformation.new(
        name: method.name,
        kind: method.macro ? LSP::SymbolKind::Function : LSP::SymbolKind::Method,
        deprecated: false,
        location: LSP::Location.new(
          uri: "file://#{loc.filename}",
          range: LSP::Range.new(
            start: LSP::Position.new(line: loc.line_number - 1, character: loc.column_number - 1),
            end: LSP::Position.new(line: loc.line_number - 1, character: loc.column_number - 1 + method.name_size)
          )
        ),
        container_name: container_name
      )
    end
  end

  private def fix_source(source : String) : String
    # LSP::Log.info { "Fixing source: #{source}" }
    Crystal::Parser.parse(source)
    # LSP::Log.info { "No need to fix source!" }
    source
  rescue
    fixed_source = BrokenSourceFixer.fix(source)
    # LSP::Log.info { "Fixed source: #{fixed_source}" }
    fixed_source
  end
end
