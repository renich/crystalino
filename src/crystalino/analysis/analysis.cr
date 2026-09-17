require "../diagnostics"
require "./cursor_visitor"
require "./submodule_visitor"

module Crystalino::Analysis
  # Dedicated execution-contexts runtime (Crystal >= 1.21): run compilation fibers
  # on a dedicated single-worker parallel context, so compiles never block the LSP event loop.
  @@compile_context : Fiber::ExecutionContext::Parallel = Fiber::ExecutionContext::Parallel.new("crystalino-compile", 1)

  private def self.spawn_dedicated(*, name : String? = nil, &block)
    @@compile_context.spawn(name: name, &block)
  end

  # Runs *block* on the dedicated compile context and waits for its result.
  # Keeps CPU-heavy work (compiles, index/summary builds) off the LSP event
  # loop whenever the runtime provides a parallel context.
  def self.run_dedicated(&block : -> T) : T forall T
    reply_channel = Channel(T | Exception).new
    spawn_dedicated do
      reply_channel.send(block.call)
    rescue e : Exception
      reply_channel.send(e)
    end
    result = reply_channel.receive
    raise result if result.is_a?(Exception)
    result
  end

  # Compile a target *file_uri*.
  def self.compile(server : LSP::Server, file_uri : URI, *, lib_path : String? = nil, file_overrides : Hash(String, String)? = nil, ignore_diagnostics = false, wants_doc = false, fail_fast = false, top_level = false, compiler_flags : Array(String) = [] of String) : Crystal::Compiler::Result?
    if file_uri.scheme == "file"
      file = File.new file_uri.decoded_path
      sources = [
        Crystal::Compiler::Source.new(file_uri.decoded_path, file.gets_to_end),
      ]
      file.close
      self.compile(server, sources, lib_path: lib_path, file_overrides: file_overrides, ignore_diagnostics: ignore_diagnostics, wants_doc: wants_doc, fail_fast: fail_fast, top_level: top_level, compiler_flags: compiler_flags)
    end
  end

  # Compile an array of *sources*.
  def self.compile(server : LSP::Server, sources : Array(Crystal::Compiler::Source), *, lib_path : String? = nil, file_overrides : Hash(String, String)? = nil, ignore_diagnostics = false, wants_doc = false, fail_fast = false, top_level = false, compiler_flags : Array(String) = [] of String)
    diagnostics = Diagnostics.new
    reply_channel = Channel(Crystal::Compiler::Result | Exception).new

    # LSP::Log.info { "sources: #{sources.map(&.filename)}" }
    # LSP::Log.info { "lib_path: #{lib_path}" }
    LSP::Log.info { "compiler_flags: #{compiler_flags}" }

    # Delegate heavy processing to a separate thread.
    spawn_dedicated do
      dev_null = File.open(File::NULL, "w")
      compiler = Crystal::Compiler.new
      compiler.no_codegen = true
      compiler.color = false
      compiler.no_cleanup = true
      compiler.file_overrides = file_overrides
      compiler.wants_doc = wants_doc
      compiler.stdout = dev_null
      compiler.stderr = dev_null
      compiler.flags = compiler_flags

      if lib_path_override = lib_path
        path = Crystal::CrystalPath.default_path_without_lib.split(Process::PATH_DELIMITER)
        path.insert(0, lib_path_override)
        compiler.crystal_path = Crystal::CrystalPath.new(path)
      end

      reply = begin
        if top_level
          # Top level only.
          compiler.top_level_semantic(sources)
        elsif fail_fast
          # Regular parser + semantic analysis phases.
          compiler.compile(sources, "")
        else
          # Error tolerant means that errors are collected instead of throwing during the semantic phase, and we still get a partially typed AST back.
          compiler.error_tolerant_compile(sources, "")
        end
      end
      reply_channel.send(reply)
    rescue e : Exception
      reply_channel.send(e)
    ensure
      dev_null.try &.close
    end
    result = reply_channel.receive

    raise result if result.is_a? Exception

    unless ignore_diagnostics
      process_diagnostics(result, diagnostics)
    end

    result
  rescue e : Exception
    if e.is_a?(Crystal::TypeException) || e.is_a?(Crystal::SyntaxException)
      LSP::Log.debug(exception: e) { "#{e}" }
      diagnostics.try &.append_from_exception(e) unless ignore_diagnostics
    else
      LSP::Log.debug(exception: e) { "#{e.message}\n#{e.backtrace?}" }
    end
    nil
  ensure
    # Propagate diagnostics to the client.
    diagnostics.try &.publish(server) unless ignore_diagnostics
  end

  private def self.process_diagnostics(result : Crystal::Compiler::Result, diagnostics : Diagnostics)
    result.program.requires.each do |path|
      diagnostics.init_value("file://#{path}")
    end

    result.program.error_stack.try &.each do |e|
      next unless e.is_a?(Crystal::TypeException) || e.is_a?(Crystal::SyntaxException)
      # The error-tolerant semantic can emit bogus errors inside the stdlib's
      # llvm wrapper (e.g. Bool-to-Int32 conversions that a regular compile
      # never reports, see di_builder.cr). Real user-facing errors surface at
      # the user's call site instead, so these are safe to skip.
      next if stdlib_llvm_error?(e)
      diagnostics.append_from_exception(e)
    end
  end

  # True when the error is located inside the stdlib's llvm wrapper, where the
  # error-tolerant semantic can report errors a regular compile never does.
  private def self.stdlib_llvm_error?(e : Crystal::CodeError) : Bool
    return false unless e.is_a?(Crystal::TypeException)

    filename = e.filename
    return false unless filename

    filename.to_s.includes?("/src/llvm/") || filename.to_s.includes?("\\src\\llvm\\")
  end

  # Return the node at the given *location*.
  def self.node_at_cursor(result : Crystal::Compiler::Result, location : Crystal::Location) : Crystal::ASTNode?
    nodes, _ = CursorVisitor.new(location).process(result)
    nodes.last?
  end

  # Return the whole hierarchy of nodes at the given *location*.
  def self.nodes_at_cursor(result : Crystal::Compiler::Result, location : Crystal::Location) : {Array(Crystal::ASTNode), Hash(String, {Crystal::Type?, Crystal::Location?})}
    CursorVisitor.new(location).process(result)
  end

  record Definitions, node : Crystal::ASTNode, locations : Array({Crystal::Location, Crystal::Location})?

  # Return the possible definition for the node at the given *location*.
  def self.definitions_at_cursor(result : Crystal::Compiler::Result, location : Crystal::Location) : Definitions?
    nodes, context = CursorVisitor.new(location).process(result)
    nodes.last?.try { |node|
      LSP::Log.debug { "Class of node at cursor: #{node.class} " }
      locations = get_locations_for_node(node, result, nodes, context)
      Definitions.new(node: node, locations: locations)
    }
  end

  private def self.get_locations_for_node(node : Crystal::ASTNode, result : Crystal::Compiler::Result, nodes : Array(Crystal::ASTNode), context : Hash(String, {Crystal::Type?, Crystal::Location?}))
    case node
    when Crystal::Call
      locations_for_call(node)
    when Crystal::Require
      locations_for_require(node, result)
    when Crystal::Path
      AstResolver.locations_from_path(node, nodes)
    when Crystal::Union
      AstResolver.locations_from_union(node, nodes)
    when Crystal::Var
      locations_for_var(node, context)
    when Crystal::InstanceVar
      locations_for_ivar(node, context)
    when Crystal::ClassVar
      locations_for_cvar(node, context)
    end
  end

  private def self.locations_for_call(node : Crystal::Call)
    if defs = node.target_defs
      locations_for_target_defs(defs)
    elsif expanded_macro = node.expanded_macro
      locations_for_expanded_macro(expanded_macro)
    end
  end

  private def self.locations_for_target_defs(defs)
    defs.compact_map { |target_def|
      start_location = target_def.location.try { |loc| loc.expanded_location || loc }
      end_location = target_def.end_location.try { |loc| loc.expanded_location || loc }
      {start_location, end_location} if start_location && end_location
    }
  end

  private def self.locations_for_expanded_macro(expanded_macro)
    start_location = expanded_macro.location.try { |loc| loc.expanded_location || loc }
    if start_location
      end_location = expanded_macro.end_location.try { |loc| loc.expanded_location || loc } || start_location
      [{start_location, end_location}]
    end
  end

  private def self.locations_for_require(node : Crystal::Require, result : Crystal::Compiler::Result)
    location = node.location
    filename = node.string
    relative_to = location.try &.original_filename
    filenames = result.program.find_in_path(filename, relative_to)
    filenames.try &.map { |path|
      location = Crystal::Location.new(
        path,
        line_number: 1,
        column_number: 1
      )
      {location, location}
    }
  end

  private def self.locations_for_var(node : Crystal::Var, context : Hash(String, {Crystal::Type?, Crystal::Location?}))
    if definition = context[node.to_s]?
      _, location = definition
      [{location, location}] if location
    end
  end

  private def self.locations_for_ivar(node : Crystal::InstanceVar, context : Hash(String, {Crystal::Type?, Crystal::Location?}))
    if ivar = context["self"]?.try &.[0].try &.lookup_instance_var? node.name
      if location = ivar.location
        [{location, location}]
      end
    end
  end

  private def self.locations_for_cvar(node : Crystal::ClassVar, context : Hash(String, {Crystal::Type?, Crystal::Location?}))
    if cvar = context["self"]?.try &.[0].try &.all_class_vars[node.name]? # lookup_raw_class_var? node.name
      if location = cvar.location
        [{location, location}]
      end
    end
  end

  def self.all_defs(type, *, accumulator = [] of {String, Crystal::Def, Crystal::Type, Int32}, nesting = 0)
    if type.is_a? Crystal::UnionType
      # todo: intersection instead of union
      type.union_types.each { |union_type|
        all_defs(union_type, accumulator: accumulator, nesting: nesting)
      }
      return accumulator.uniq &.[1]
    end

    type.defs.try &.each do |def_name, defs_with_metadata|
      defs_with_metadata.each do |def_with_metadata|
        definition = def_with_metadata.def
        body = definition.body

        next if body.is_a?(Crystal::Primitive) && body.name == "allocate"
        next if def_name == "set_crystal_type_id"

        accumulator << {def_name, definition, type, nesting}
      end
    end

    type.parents.try &.each do |parent|
      if type.responds_to? :instance_type
        extends_self = type.instance_type == parent
      end
      self.all_defs(parent, accumulator: accumulator, nesting: extends_self ? nesting : nesting + 1)
    end

    accumulator
  end

  def self.all_macros(type, *, accumulator = [] of {String, Crystal::Macro, Crystal::Type, Int32}, nesting = 0)
    if type.is_a? Crystal::UnionType
      type.union_types.each { |union_type|
        all_macros(union_type, accumulator: accumulator, nesting: nesting)
      }
      return accumulator.uniq &.[0]
    end

    type.macros.try &.each do |macro_name, macros|
      macros.each do |macro_def|
        accumulator << {macro_name, macro_def, type, nesting}
      end
    end

    type.parents.try &.each do |parent|
      self.all_macros(parent, accumulator: accumulator, nesting: nesting + 1)
    end

    accumulator
  end

  def self.all_submodules(result : Crystal::Compiler::Result, module_type : Crystal::Type) : Array(Crystal::ModuleType)
    SubModuleVisitor.new(module_type).process_result(result)
  end

  def self.context_at(result : Crystal::Compiler::Result, location : Crystal::Location) : Hash(String, Crystal::Type)?
    Crystal::ContextVisitor.new(location).process(result).contexts.try &.last?
  end
end
