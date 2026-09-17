require "compiler/crystal/syntax"
require "./type_utils"

module Crystalino::Lightweight
  enum TypeKind
    Class
    Module
    Struct
    Enum
    Annotation
    Alias
    Lib
    Constant
    Unknown
  end

  record ArgInfo, name : String, restriction : String?, default_value : String? = nil

  record MethodInfo,
    name : String,
    owner : String,
    args : Array(ArgInfo),
    return_type : String?,
    class_method : Bool = false,
    macro : Bool = false,
    doc : String? = nil,
    location : Crystal::Location? = nil,
    name_location : Crystal::Location? = nil,
    name_size : Int32 = 0,
    free_vars : Array(String) = [] of String,
    block_restriction : String? = nil

  class TypeInfo
    getter name : String
    getter kind : TypeKind
    getter doc : String?
    getter methods = [] of MethodInfo
    getter subtypes = [] of String
    getter parent_types = [] of String
    getter location : Crystal::Location?
    getter name_location : Crystal::Location?
    getter ivars = {} of String => Array(String)
    getter class_vars = {} of String => Array(String)
    # `delegate foo, bar, to: @array` — macro-generated passthrough
    # methods: method name -> delegate target expression (`@array`). The
    # query resolves them against the target's indexed type.
    getter delegates = {} of String => String
    # `forward_missing_to @array` — every unknown method delegates.
    property forward_missing_to : String?

    def initialize(@name : String, @kind : TypeKind, @doc : String? = nil, @location : Crystal::Location? = nil, @name_location : Crystal::Location? = nil)
    end
  end

  class Index
    getter types = {} of String => TypeInfo
    getter top_level_methods = [] of MethodInfo
    # Word-list constants (`COLORS = %w(...)`) that `{% for name in COLORS %}`
    # loops iterate: filled while walking this index's own source.
    @constant_word_lists = {} of String => Array(String)

    # Merges several indexes into one (e.g. the project's source files).
    # A type defined in several indexes (e.g. `Crystal::ASTNode` split
    # across compiler files) keeps the union of its methods, parents,
    # subtypes and ivars instead of letting the last definition win.
    def self.merge(indexes : Array(Index)) : Index
      merged = Index.new
      indexes.each do |index|
        index.types.each do |name, type|
          if existing = merged.types[name]?
            type.methods.each do |method|
              if existing_index = existing.methods.index { |method_info| same_method?(method_info, method) }
                # The compiled (semantic) def often drops the block
                # restriction (`(T -> _)`); the source-derived one carries
                # the real declaration. Prefer the richer method.
                existing_restriction = existing.methods[existing_index].block_restriction
                if existing_restriction.nil? || existing_restriction.includes?('_')
                  new_restriction = method.block_restriction
                  if new_restriction && !new_restriction.includes?('_')
                    existing.methods[existing_index] = method
                  end
                end
                # The semantic def also drops typed return types on free-var
                # methods (`group_by` keeps `(T -> U)` but loses
                # `Hash(U, Array(T))`): the source declaration wins.
                if existing.methods[existing_index].return_type.nil? && method.return_type
                  existing.methods[existing_index] = method
                end
              else
                existing.methods << method
              end
            end
            type.parent_types.each { |parent| existing.parent_types << parent unless existing.parent_types.includes?(parent) }
            type.subtypes.each { |subtype| existing.subtypes << subtype unless existing.subtypes.includes?(subtype) }
            type.ivars.each { |k, v| (existing.ivars[k] ||= [] of String).concat(v).uniq! }
            type.class_vars.each { |k, v| (existing.class_vars[k] ||= [] of String).concat(v).uniq! }
            type.delegates.each { |k, v| existing.delegates[k] = v unless existing.delegates.has_key?(k) }
            existing.forward_missing_to ||= type.forward_missing_to
          else
            merged.types[name] = type
          end
        end
        merged.top_level_methods.concat(index.top_level_methods)
      end
      merged
    end

    # True when two method infos share the same name, owner and signature,
    # so an overlay redefinition can be matched against an indexed one.
    # The location is deliberately not compared: a same-signature method
    # from a newer source wins when its location differs.
    def self.same_method?(left : MethodInfo, right : MethodInfo) : Bool
      left.name == right.name &&
        left.owner == right.owner &&
        left.class_method == right.class_method &&
        left.macro == right.macro &&
        left.args.map(&.restriction) == right.args.map(&.restriction)
    end

    def self.from_program(program : Crystal::Program) : self
      new.tap do |index|
        program.types.each_value do |type|
          index.index_type(type)
        end

        if defs = program.defs
          defs.each_value do |items|
            items.each do |item|
              index.top_level_methods << index.method_info_for(item.def, owner: "::")
            end
          end
        end
      end
    end

    def self.from_source(source : String, filename : String? = nil) : self?
      parser = Crystal::Parser.new(source)
      parser.wants_doc = true
      # The parser defaults locations to an empty filename: leave it alone
      # unless a real one is given, so same-source locations stay comparable.
      parser.filename = filename if filename
      ast = parser.parse

      new.tap do |index|
        index.index_syntax_node(ast)
      end
    rescue Crystal::SyntaxException
      nil
    end

    protected def index_syntax_node(node : Crystal::ASTNode, namespace : String? = nil)
      case node
      when Crystal::Expressions, Crystal::Assign, Crystal::VisibilityModifier, Crystal::Def, Crystal::Macro, Crystal::Call
        index_syntax_node_statement(node, namespace)
      when Crystal::ClassDef, Crystal::ModuleDef, Crystal::EnumDef, Crystal::AnnotationDef, Crystal::Alias
        index_syntax_node_type(node, namespace)
      end
    end

    private def index_syntax_node_statement(node : Crystal::ASTNode, namespace : String?)
      case node
      when Crystal::Expressions        then node.expressions.each { |e| index_syntax_node(e, namespace) }
      when Crystal::Assign             then index_constant_word_list(node)
      when Crystal::VisibilityModifier then index_visibility_modifier(node, namespace)
      when Crystal::Def                then index_def_node(node)
      when Crystal::Macro              then index_macro_body(node.body, namespace)
      when Crystal::Call               then index_record_call(node, namespace)
      end
    end

    private def index_syntax_node_type(node : Crystal::ASTNode, namespace : String?)
      case node
      when Crystal::ClassDef      then index_class_def(node, namespace)
      when Crystal::ModuleDef     then index_module_def(node, namespace)
      when Crystal::EnumDef       then index_enum_def(node, namespace)
      when Crystal::AnnotationDef then index_annotation_def(node, namespace)
      when Crystal::Alias         then index_alias_def(node, namespace)
      end
    end

    private def index_visibility_modifier(node : Crystal::VisibilityModifier, namespace : String?)
      if assign = node.exp.as?(Crystal::Assign)
        index_constant_word_list(assign)
      end
      index_syntax_node(node.exp, namespace)
    end

    private def index_def_node(node : Crystal::Def)
      return if node.receiver
      @top_level_methods << method_info_for(node, owner: "::")
    end

    private def index_class_def(node : Crystal::ClassDef, namespace : String?)
      type_name = qualify_type_name(generic_type_name(node.name, node.type_vars), namespace)
      type_info = (@types[type_name] ||= TypeInfo.new(type_name, node.struct? ? TypeKind::Struct : TypeKind::Class, node.doc, node.location, node.name_location))
      if superclass = node.superclass
        superclass_name = superclass.to_s
        type_info.parent_types << superclass_name unless type_info.parent_types.includes?(superclass_name)
      elsif node.struct?
        type_info.parent_types << "Struct" unless type_info.parent_types.includes?("Struct")
      else
        type_info.parent_types << "Reference" unless type_info.parent_types.includes?("Reference")
      end
      index_syntax_type_body(type_info, node.body, type_name)
      index_new_method(type_info, type_name)
    end

    private def index_module_def(node : Crystal::ModuleDef, namespace : String?)
      type_name = qualify_type_name(generic_type_name(node.name, node.type_vars), namespace)
      type_info = (@types[type_name] ||= TypeInfo.new(type_name, TypeKind::Module, node.doc, node.location, node.name_location))
      index_syntax_type_body(type_info, node.body, type_name)
    end

    private def index_enum_def(node : Crystal::EnumDef, namespace : String?)
      type_name = qualify_type_name(node.name.to_s, namespace)
      type_info = (@types[type_name] ||= TypeInfo.new(type_name, TypeKind::Enum, node.doc, node.location, node.name_location))
      type_info.parent_types << "Enum" unless type_info.parent_types.includes?("Enum")

      node.members.each do |member|
        member_name = case member
                      when Crystal::Arg    then member.name
                      when Crystal::Path   then member.to_s
                      when Crystal::Assign then member.target.is_a?(Crystal::Path) ? member.target.to_s : nil
                      end
        next unless member_name
        type_info.subtypes << member_name unless type_info.subtypes.includes?(member_name)

        predicate = "#{member_name.underscore}?"
        next if type_info.methods.any? { |method_info| method_info.name == predicate }
        type_info.methods << MethodInfo.new(
          name: predicate,
          owner: type_name,
          args: [] of ArgInfo,
          return_type: "Bool",
        )
      end
    end

    private def index_annotation_def(node : Crystal::AnnotationDef, namespace : String?)
      type_name = qualify_type_name(node.name.to_s, namespace)
      @types[type_name] ||= TypeInfo.new(type_name, TypeKind::Annotation, node.doc, node.location, node.name_location)
    end

    private def index_alias_def(node : Crystal::Alias, namespace : String?)
      type_name = qualify_type_name(node.name.to_s, namespace)
      type_info = (@types[type_name] ||= TypeInfo.new(type_name, TypeKind::Alias, node.doc, node.location, node.name_location))
      aliased_name = node.value.to_s
      type_info.parent_types << aliased_name unless type_info.parent_types.includes?(aliased_name)
    end

    protected def index_macro_body(node : Crystal::ASTNode, namespace : String?)
      return unless node.is_a?(Crystal::Expressions)
      # The macro body parses as a sequence of MacroLiterals whose
      # boundaries do not align with the code's own structure (a
      # `class ... end` may span several literals): concatenate the raw
      # text and parse it as one unit.
      text = String.build do |io|
        node.expressions.each do |expression|
          io << expression.value if expression.is_a?(Crystal::MacroLiteral)
        end
      end
      return if text.strip.empty?
      reparsed = Crystal::Parser.new(text).parse
      index_syntax_node(reparsed, namespace)
    rescue Crystal::SyntaxException
      # Spliced interpolations (`{{ ... }}`) may not parse on their
      # own: skip macros that do not parse cleanly.
    end

    # Macro control-flow branches (`{% if ... %}` / `{% for ... %}`)
    # parse as raw MacroLiteral text: re-parse it and index it as
    # type-body code, so class vars, ivars and defs inside the branch
    # resolve before the first compile.
    protected def index_macro_branch(node : Crystal::ASTNode, type_info : TypeInfo, type_name : String)
      text = String.build do |io|
        case node
        when Crystal::Expressions
          node.expressions.each do |expression|
            io << expression.value if expression.is_a?(Crystal::MacroLiteral)
          end
        when Crystal::MacroLiteral
          io << node.value
        end
      end
      return if text.strip.empty?
      reparsed = Crystal::Parser.new(text).parse
      index_syntax_type_body(type_info, reparsed, type_name)
    rescue Crystal::SyntaxException
      # Spliced interpolations may not parse on their own: skip.
    end

    # `{% for name in %w(...) %}` loops over literal word lists generate
    # one body per iteration (`class {{name.id}}; include ExpandableNode; end`):
    # expand the interpolation per word and index each generated body, so
    # loop-generated reopenings merge into the real types (the raw body
    # cannot re-parse with the interpolation intact).
    protected def index_macro_for(node : Crystal::MacroFor, type_info : TypeInfo, type_name : String)
      words = macro_for_words(node.exp)
      if words.empty?
        index_macro_branch(node.body, type_info, type_name)
        return
      end

      text = String.build do |io|
        node.body.try do |body|
          case body
          when Crystal::Expressions
            body.expressions.each do |expression|
              case expression
              when Crystal::MacroLiteral
                io << expression.value
              when Crystal::MacroExpression
                # `{{ name.id }}` interpolates the loop variable: keep the
                # marker text so the per-word expansion below can replace it.
                io << expression.to_s
              end
            end
          when Crystal::MacroLiteral
            io << body.value
          end
        end
      end
      return if text.strip.empty?

      # Single-variable loops (`{% for name in %w(...) %}`) interpolate
      # `{{name.id}}`; multi-variable loops (a `%w` of pairs) fall back to
      # the raw reparse below.
      if (loop_var = node.vars.first?) && node.vars.size == 1
        interpolation = /\{\{\s*#{Regex.escape(loop_var.name)}\.id\s*\}\}/
        # `{{name.camelcase.id}}` (e.g. `ColorANSI::{{name.camelcase.id}}`)
        # and `{{mode.underscore.id}}` (enum member loops): the reparse
        # would otherwise throw on the macro expression and skip the loop.
        camelcase_interpolation = /\{\{\s*#{Regex.escape(loop_var.name)}\.camelcase\.id\s*\}\}/
        underscore_interpolation = /\{\{\s*#{Regex.escape(loop_var.name)}\.underscore\.id\s*\}\}/
        words.each do |word|
          expanded = text
            .gsub(interpolation, word)
            .gsub(camelcase_interpolation, word.camelcase)
            .gsub(underscore_interpolation, word.underscore)
          reparsed = Crystal::Parser.new(expanded).parse
          index_syntax_type_body(type_info, reparsed, type_name)
        end
        return
      end

      index_macro_branch(node.body, type_info, type_name)
    rescue Crystal::SyntaxException
      # An iteration may not parse on its own: skip the loop.
    end

    # The word list of `{% for x in %w(a b c) %}`: parses as an array
    # literal of strings, or as raw macro text in macro context. The
    # collection may also name a constant (`{% for name in COLORS %}`)
    # whose `%w(...)` value was registered by index_constant_word_list.
    private def macro_for_words(node : Crystal::ASTNode?) : Array(String)
      return [] of String unless node
      case node
      when Crystal::ArrayLiteral
        node.elements.compact_map { |element| element.as?(Crystal::StringLiteral).try(&.value) }
      when Crystal::MacroLiteral
        if match = node.value.match(/^\s*%w\(([^)]*)\)/)
          match[1].split
        elsif words = @constant_word_lists[node.value.strip]?
          words
        else
          [] of String
        end
      when Crystal::Path
        @constant_word_lists[node.to_s]? || [] of String
      when Crystal::Call
        macro_for_words_from_call(node)
      else
        [] of String
      end
    end

    private def macro_for_words_from_call(node : Crystal::Call) : Array(String)
      collection = node
      collection = collection.obj.as(Crystal::Call) if collection.name == "reject" && collection.obj.is_a?(Crystal::Call)
      if collection.is_a?(Crystal::Call) && collection.name == "constants"
        if enum_path = collection.obj.as?(Crystal::Path)
          enum_name = @types.keys.find { |key| key == enum_path.to_s || key.ends_with?("::#{enum_path}") }
          if enum_name && (enum_type = @types[enum_name]?)
            return enum_type.subtypes
          end
        end
      end
      [] of String
    end

    # `COLORS = %w(default red ...)` — records the word list under the
    # constant name so `{% for name in COLORS %}` loops (the stdlib's
    # Colorize styles, terminal ANSI names, ...) expand per word.
    private def index_constant_word_list(node : Crystal::Assign)
      return unless node.target.is_a?(Crystal::Path)
      words = case value = node.value
              when Crystal::ArrayLiteral
                value.elements.compact_map { |element| element.as?(Crystal::StringLiteral).try(&.value) }
              when Crystal::MacroLiteral
                value.value.match(/^\s*%w\(([^)]*)\)/).try(&.[1].split) || [] of String
              else
                [] of String
              end
      @constant_word_lists[node.target.to_s] = words unless words.empty?
    end

    protected def index_syntax_type_body(type_info : TypeInfo, node : Crystal::ASTNode, type_name : String)
      case node
      when Crystal::Expressions
        node.expressions.each do |expression|
          index_syntax_type_body_node(type_info, expression, type_name)
        end
      else
        index_syntax_type_body_node(type_info, node, type_name)
      end
    end

    private def index_syntax_type_body_node(type_info : TypeInfo, node : Crystal::ASTNode, type_name : String)
      case node
      when Crystal::Def, Crystal::VisibilityModifier, Crystal::Call, Crystal::Macro, Crystal::TypeDeclaration, Crystal::Assign, Crystal::MacroIf, Crystal::MacroFor
        index_syntax_type_body_statement(type_info, node, type_name)
      when Crystal::ClassDef, Crystal::ModuleDef, Crystal::EnumDef, Crystal::AnnotationDef, Crystal::Alias, Crystal::Include, Crystal::Extend
        index_syntax_type_body_type(type_info, node, type_name)
      end
    end

    private def index_syntax_type_body_statement(type_info : TypeInfo, node : Crystal::ASTNode, type_name : String)
      case node
      when Crystal::Def
        type_info.methods << method_info_for(node, owner: type_name, class_method: !node.receiver.nil?)
        index_ivar_assignments(node.body, type_info)
        index_shorthand_ivar_args(node, type_info)
      when Crystal::VisibilityModifier
        if inner_def = node.exp.as?(Crystal::Def)
          type_info.methods << method_info_for(inner_def, owner: type_name, class_method: !inner_def.receiver.nil?)
          index_ivar_assignments(inner_def.body, type_info)
          index_shorthand_ivar_args(inner_def, type_info)
        elsif assign = node.exp.as?(Crystal::Assign)
          index_constant_word_list(assign)
        end
      when Crystal::Call
        index_accessor_call(node, type_info, type_name)
        index_record_call(node, type_name)
        index_delegate_call(node, type_info)
      when Crystal::TypeDeclaration
        index_ivar_declaration(node, type_info)
      when Crystal::Assign
        index_ivar_assignment(node, type_info)
      when Crystal::Macro, Crystal::MacroIf, Crystal::MacroFor
        index_syntax_type_body_macro(type_info, node, type_name)
      end
    end

    private def index_syntax_type_body_macro(type_info : TypeInfo, node : Crystal::ASTNode, type_name : String)
      case node
      when Crystal::Macro
        index_macro_body(node.body, type_name)
      when Crystal::MacroIf
        index_macro_branch(node.then, type_info, type_name)
        node.else.try { |e| index_macro_branch(e, type_info, type_name) }
      when Crystal::MacroFor
        index_macro_for(node, type_info, type_name)
      end
    end

    private def index_syntax_type_body_type(type_info : TypeInfo, node : Crystal::ASTNode, type_name : String)
      case node
      when Crystal::ClassDef, Crystal::ModuleDef, Crystal::EnumDef, Crystal::AnnotationDef
        index_nested_type(node, type_info, type_name)
      when Crystal::Alias
        index_alias(node, type_name)
      when Crystal::Include, Crystal::Extend
        index_include(node, type_info)
      end
    end

    # Records class-level ivar declarations (`@x : T`), so receivers resolve
    # from the very first keystroke, before any compile.
    private def index_ivar_declaration(node : Crystal::TypeDeclaration, type_info : TypeInfo)
      return unless declared_type = node.declared_type
      case var = node.var
      when Crystal::InstanceVar
        (type_info.ivars[var.name] ||= [] of String) << declared_type.to_s
      when Crystal::ClassVar
        (type_info.class_vars[var.name] ||= [] of String) << declared_type.to_s
      end
    end

    # Records class-level ivar assignments (`@x = value`), which are the only
    # declaration form for ivars without a type restriction. `||=` counts too
    # (`@cache ||= {} of ...`).
    private def index_ivar_assignment(node : Crystal::Assign | Crystal::OpAssign, type_info : TypeInfo)
      return unless value_type = syntax_value_type_name(node.value)
      case target = node.target
      when Crystal::InstanceVar
        (type_info.ivars[target.name] ||= [] of String) << value_type
      when Crystal::ClassVar
        (type_info.class_vars[target.name] ||= [] of String) << value_type
      end
    end

    # Best-effort type name for a class-level ivar initializer (`Mutex.new` →
    # `Mutex`, `"str"` → `String`); the query resolves it against the merged
    # index afterwards.
    private def syntax_value_type_name(node : Crystal::ASTNode) : String?
      case node
      when Crystal::Call
        node.obj.try { |obj| syntax_value_type_name(obj) }
      when Crystal::Path, Crystal::Generic
        node.to_s
      when Crystal::ArrayLiteral, Crystal::HashLiteral, Crystal::TupleLiteral, Crystal::NamedTupleLiteral
        syntax_value_collection_type_name(node)
      when Crystal::StringLiteral, Crystal::BoolLiteral, Crystal::NumberLiteral, Crystal::NilLiteral, Crystal::RangeLiteral, Crystal::RegexLiteral, Crystal::SymbolLiteral
        syntax_value_scalar_type_name(node)
      end
    end

    private def syntax_value_collection_type_name(node : Crystal::ASTNode) : String?
      case node
      when Crystal::ArrayLiteral
        node.of.try { |of_type| "Array(#{of_type})" } || "Array"
      when Crystal::HashLiteral
        if entry = node.of
          "Hash(#{entry.key}, #{entry.value})"
        else
          "Hash"
        end
      when Crystal::TupleLiteral      then "Tuple"
      when Crystal::NamedTupleLiteral then "NamedTuple"
      end
    end

    private def syntax_value_scalar_type_name(node : Crystal::ASTNode) : String?
      case node
      when Crystal::StringLiteral then "String"
      when Crystal::BoolLiteral   then "Bool"
      when Crystal::NumberLiteral then "Number"
      when Crystal::NilLiteral    then "Nil"
      when Crystal::RangeLiteral  then "Range"
      when Crystal::RegexLiteral  then "Regex"
      when Crystal::SymbolLiteral then "Symbol"
      end
    end

    # Collects ivar assignments inside method bodies (`@x = value`), so ivars
    # initialized in a method resolve as receivers from any other method too.
    private def index_ivar_assignments(node : Crystal::ASTNode, type_info : TypeInfo)
      case node
      when Crystal::Expressions
        node.expressions.each { |expression| index_ivar_assignments(expression, type_info) }
      when Crystal::Assign, Crystal::OpAssign
        index_ivar_assignment(node, type_info)
      when Crystal::Call
        node.block.try { |block| index_ivar_assignments(block, type_info) }
      when Crystal::ExceptionHandler, Crystal::If, Crystal::Unless, Crystal::Case, Crystal::While, Crystal::Until, Crystal::Block
        index_ivar_assignments_control_flow(node, type_info)
      end
    end

    private def index_ivar_assignments_control_flow(node : Crystal::ASTNode, type_info : TypeInfo)
      case node
      when Crystal::ExceptionHandler
        index_ivar_assignments(node.body, type_info)
        node.rescues.try { |rescues| rescues.each { |rescue_clause| index_ivar_assignments(rescue_clause.body, type_info) } }
        node.else.try { |else_node| index_ivar_assignments(else_node, type_info) }
      when Crystal::If, Crystal::Unless
        index_ivar_assignments(node.then, type_info)
        index_ivar_assignments(node.else, type_info)
      when Crystal::Case
        node.whens.each { |a_when| index_ivar_assignments(a_when.body, type_info) }
        node.else.try { |e| index_ivar_assignments(e, type_info) }
      when Crystal::While, Crystal::Until, Crystal::Block
        index_ivar_assignments(node.body, type_info)
      end
    end

    ACCESSOR_MACROS = %w[getter setter property getter? setter? property? class_getter class_setter class_property class_getter? class_setter? class_property? getter! setter! property! class_getter! class_setter! class_property!]

    # An alias (`alias Handler = Proc(...)`) inside a type or module body:
    # index it like a top-level alias so receivers of the alias resolve.
    private def index_alias(node : Crystal::Alias, type_name : String)
      alias_name = qualify_type_name(node.name.to_s, type_name)
      alias_info = (@types[alias_name] ||= TypeInfo.new(alias_name, TypeKind::Alias, node.doc, node.location, node.name_location))
      aliased_name = node.value.to_s
      alias_info.parent_types << aliased_name unless alias_info.parent_types.includes?(aliased_name)
    end

    # `include Foo` / `extend Foo` make the module's methods available on
    # the type: record it as a parent so methods_for walks into it
    # (e.g. `process_result` from `Crystal::TypedDefProcessor`).
    private def index_include(node : Crystal::Include | Crystal::Extend, type_info : TypeInfo)
      name = node.name.to_s
      type_info.parent_types << name unless type_info.parent_types.includes?(name)
    end

    # `new` is compiler-synthesized from `initialize`: synthesize a class
    # method so `Class.` completion and hovers offer it. Args come from
    # the class's own `initialize` when present, otherwise `new` is bare.
    private def index_new_method(type_info : TypeInfo, type_name : String)
      return if type_info.methods.any? { |method_info| method_info.class_method && method_info.name == "new" }
      initialize_method = type_info.methods.find { |method_info| !method_info.class_method && method_info.name == "initialize" }
      type_info.methods << MethodInfo.new(
        name: "new",
        owner: type_name,
        args: initialize_method.try(&.args) || [] of ArgInfo,
        return_type: type_name,
        class_method: true,
        doc: nil,
        location: initialize_method.try(&.location),
      )
    end

    # A `delegate` macro-expanded def is a passthrough
    # (`def shift(*args, **kwargs); @array.shift(*args, **kwargs); end`):
    # the target ivar names it so the query resolves the delegated method
    # through the target's typed methods. Requires the call name to match
    # the def name, an ivar receiver, no block, and every argument to be a
    # bare splat var — anything else is a real method body.
    private def delegate_passthrough_target(definition : Crystal::Def) : String?
      body = definition.body
      body = body.expressions.first? if body.is_a?(Crystal::Expressions) && body.expressions.size == 1
      call = body.as?(Crystal::Call)
      return unless call
      return unless call.name == definition.name.to_s
      return if call.block
      obj = call.obj
      return unless obj.is_a?(Crystal::InstanceVar)
      return unless call.args.all? do |arg|
                      # `*args` / `**options` parse as Splat/DoubleSplat wrappers around
                      # the vars (the semantic def's arg list drops the double-splat
                      # arg, so only the bareness is checked here); plain args must be
                      # bare vars matching a def arg (setter-style passthroughs).
                      case arg
                      when Crystal::Splat, Crystal::DoubleSplat
                        exp = arg.is_a?(Crystal::Splat) ? arg.exp : arg.as(Crystal::DoubleSplat).exp
                        exp.is_a?(Crystal::Var)
                      when Crystal::Var
                        definition.args.any? { |definition_arg| definition_arg.name == arg.name }
                      else
                        false
                      end
                    end
      "@#{obj.name.lchop('@')}"
    end

    # `record Foo, x : Int32, y : String` parses as a call to the `record`
    # macro: synthesize a type with the fields as getters so receivers of
    # records resolve (`Crystal::Compiler::Result#node` etc.).
    private def index_record_call(call : Crystal::Call, type_name : String?)
      return if call.obj
      return unless call.name == "record"

      first = call.args.first?
      return unless first.is_a?(Crystal::Path)

      record_name = qualify_type_name(first.to_s, type_name)
      record_info = (@types[record_name] ||= TypeInfo.new(record_name, TypeKind::Struct, call.doc, call.location, first.name_location))
      # The record macro expands into a `Struct` subclass: record the
      # implicit parent so `Object`/`Reference` methods (`try`,
      # `not_nil!`, ...) resolve on records.
      record_info.parent_types << "Struct" unless record_info.parent_types.includes?("Struct")

      fields = [] of {String, String?}
      call.args[1..].each do |arg|
        field_name = case arg
                     when Crystal::Arg
                       arg.name.to_s
                     when Crystal::TypeDeclaration
                       var = arg.var
                       var.is_a?(Crystal::Var) ? var.name : nil
                     end
        next unless field_name
        restriction = arg.is_a?(Crystal::TypeDeclaration) ? arg.declared_type.to_s : arg.as(Crystal::Arg).restriction.try(&.to_s)
        fields << {field_name, restriction}
        next if record_info.methods.any? { |method_info| method_info.name == field_name }
        record_info.methods << MethodInfo.new(
          name: field_name,
          owner: record_name,
          args: [] of ArgInfo,
          return_type: restriction,
          class_method: false,
          doc: nil,
          location: call.location,
        )
      end

      # The record macro also generates `new(field, ...)`: index it so
      # `MethodInfo.new(...)` hovers and resolves its return type.
      return if record_info.methods.any? { |method_info| method_info.name == "new" && method_info.class_method }
      record_info.methods << MethodInfo.new(
        name: "new",
        owner: record_name,
        args: fields.map { |name, restriction| ArgInfo.new(name, restriction) },
        return_type: record_name,
        class_method: true,
        doc: nil,
        location: call.location,
      )
    end

    # Synthesize method entries for `getter`/`setter`/`property` macro calls,
    # which the source index cannot expand without compiling.
    protected def index_accessor_call(call : Crystal::Call, type_info : TypeInfo, type_name : String)
      macro_name = call.name.to_s
      return if call.obj
      return unless ACCESSOR_MACROS.includes?(macro_name)

      class_method = macro_name.starts_with?("class_")
      base_name = macro_name.lchop("class_")
      predicate = base_name.ends_with?("?")
      kind = base_name.rchop("?").rchop("!")

      call.args.each do |arg|
        index_accessor_arg(arg, call, type_info, type_name, kind, predicate, class_method)
      end
    end

    private def index_accessor_arg(arg : Crystal::ASTNode, call : Crystal::Call, type_info : TypeInfo, type_name : String, kind : String, predicate : Bool, class_method : Bool)
      name, restriction = accessor_arg_info(arg, type_info)
      return unless name

      if kind == "getter" || kind == "property"
        method_name = predicate ? "#{name}?" : name
        type_info.methods << MethodInfo.new(
          name: method_name,
          owner: type_name,
          args: [] of ArgInfo,
          return_type: restriction,
          class_method: class_method,
          doc: call.doc,
          location: call.location,
          name_location: call.location,
          name_size: method_name.size,
        )

        if !class_method && restriction
          (type_info.ivars["@#{name}"] ||= [] of String) << restriction
        end
        if class_method && restriction
          (type_info.class_vars["@@#{name}"] ||= [] of String) << restriction
        end
      end

      if kind == "setter" || kind == "property"
        method_name = "#{name}="
        type_info.methods << MethodInfo.new(
          name: method_name,
          owner: type_name,
          args: [ArgInfo.new(name: "value", restriction: restriction)],
          return_type: restriction,
          class_method: class_method,
          doc: call.doc,
          location: call.location,
          name_location: call.location,
          name_size: method_name.size,
        )
      end
    end

    # Synthesize delegate records for `delegate foo, bar, to: @array` and
    # `forward_missing_to @array`: the macro-generated passthrough methods
    # never appear in the source parse, so the query resolves them against
    # the target's indexed type (e.g. Priority::Queue's `first?`/`shift`
    # delegating to `@array : Array(Item(V))`).
    protected def index_delegate_call(call : Crystal::Call, type_info : TypeInfo)
      return if call.obj
      case call.name.to_s
      when "delegate"
        target = call.named_args.try(&.find { |named| named.name == "to" }).try(&.value.to_s)
        return unless target
        call.args.each do |arg|
          name = case arg
                 when Crystal::Call then arg.name.to_s
                 when Crystal::Var  then arg.name
                 else                    nil
                 end
          next unless name
          next if name.empty? || name == "to"
          type_info.delegates[name] = target unless type_info.delegates.has_key?(name)
        end
      when "forward_missing_to"
        if target = call.args.first?.try(&.to_s)
          type_info.forward_missing_to = target
        end
      end
    end

    # `def initialize(@priority : Value, @value : V)` parses the shorthand
    # args without the sigil and pushes `@priority = priority` as the body's
    # first statement: record the ivar with the arg's restriction, so
    # `property :priority`-style accessors (whose symbols carry no
    # restriction) still get a return type.
    private def index_shorthand_ivar_args(definition : Crystal::Def, type_info : TypeInfo)
      body = definition.body
      return unless body.is_a?(Crystal::Expressions)
      definition.args.each do |arg|
        next if arg.name.empty?
        next unless restriction = arg.restriction
        paired = body.expressions.any? do |expression|
          expression.is_a?(Crystal::Assign) &&
            expression.target.is_a?(Crystal::InstanceVar) &&
            expression.value.is_a?(Crystal::Var) &&
            expression.value.as(Crystal::Var).name == arg.name
        end
        next unless paired
        ivar_name = "@#{arg.name}"
        restriction_name = restriction.to_s
        ivars = (type_info.ivars[ivar_name] ||= [] of String)
        ivars << restriction_name unless ivars.includes?(restriction_name)
      end
    end

    private def accessor_arg_info(arg : Crystal::ASTNode, type_info : TypeInfo) : {String?, String?}
      case arg
      when Crystal::TypeDeclaration
        var_name = case var = arg.var
                   when Crystal::Var         then var.name
                   when Crystal::InstanceVar then var.name.lchop('@')
                   when Crystal::ClassVar    then var.name.lchop("@@")
                   else                           nil
                   end
        {var_name, arg.declared_type.to_s}
      when Crystal::Assign
        # `getter projects = [] of Project`: the initializer names the var
        # and its `of` clause names the element/key-value types.
        {accessor_target_name(arg.target), accessor_initializer_type(arg.value)}
      when Crystal::Call
        # A bare name parses as a zero-argument call.
        {arg.obj ? nil : arg.name.to_s, nil}
      when Crystal::SymbolLiteral
        # `property :priority` — the symbol names the accessor; the return
        # type falls back to the backing ivar's recorded type (from
        # `def initialize(@priority : Value, ...)` shorthands).
        {arg.value, type_info.ivars["@#{arg.value}"]?.try(&.first?)}
      else
        {nil, nil}
      end
    end

    private def accessor_target_name(target : Crystal::ASTNode) : String?
      case target
      when Crystal::Var         then target.name
      when Crystal::InstanceVar then target.name.lchop('@')
      when Crystal::ClassVar    then target.name.lchop("@@")
      else                           nil
      end
    end

    # `getter x = [] of T` / `= {} of K => V`: the initializer's `of`
    # clause declares the element (or key/value) type of the getter.
    private def accessor_initializer_type(node : Crystal::ASTNode) : String?
      case node
      when Crystal::ArrayLiteral
        node.of.try { |of_type| "Array(#{of_type})" }
      when Crystal::HashLiteral
        if entry = node.of
          "Hash(#{entry.key}, #{entry.value})"
        end
      when Crystal::Call
        # `getter requires = Set(String).new`: the receiver of `new`
        # names the getter's type (a Generic or a Path).
        if node.name == "new"
          node.obj.try(&.to_s)
        end
      end
    end

    protected def index_nested_type(node : Crystal::ClassDef | Crystal::ModuleDef | Crystal::EnumDef | Crystal::AnnotationDef, type_info : TypeInfo, type_name : String)
      nested_name = qualify_type_name(node.name.to_s, type_name)
      type_info.subtypes << nested_name unless type_info.subtypes.includes?(nested_name)
      index_syntax_node(node, type_name)
    end

    protected def qualify_type_name(name : String, namespace : String?)
      return name if namespace.nil? || name.includes?("::")
      "#{namespace}::#{name}"
    end

    # `class Set(T)` parses with the type vars detached from the name: rebuild
    # the generic form (`Set(T)`) so source generics match compiled keys.
    protected def generic_type_name(name : Crystal::Path, type_vars : Array(String)?)
      return name.to_s if type_vars.nil? || type_vars.empty?
      "#{name}(#{type_vars.join(", ")})"
    end

    protected def index_type(type : Crystal::NamedType)
      type_name = type.to_s
      type_info = (@types[type_name] ||= TypeInfo.new(type_name, kind_for(type), type.doc, type.locations.try(&.first?), type.locations.try(&.first?)))

      index_type_defs(type, type_info, type_name)
      index_type_macros(type, type_info, type_name) if type.is_a?(Crystal::ModuleType)
      index_type_metaclass_defs(type, type_info, type_name)
      index_type_parents(type, type_info)
      index_type_nested_types(type, type_info)

      # An alias (`alias Mutex = Sync::Mutex`) carries no defs of its own:
      # method lookups resolve through the aliased type, so record it as the
      # single parent for the hierarchy walk.
      if type.is_a?(Crystal::AliasType)
        if aliased = type.remove_alias
          aliased_name = aliased.to_s
          type_info.parent_types << aliased_name unless type_info.parent_types.includes?(aliased_name)
        end
      end

      # A constant (`LSP::Log = ::Log.for(self)`) holds an instance of its
      # value's type: record that type as the single parent so the resolver
      # resolves `LSP::Log.info` through the value type's instance methods
      # instead of the class-method view on the empty shell.
      if type.is_a?(Crystal::Const)
        # `type?` (not `type`): macro-only constants (e.g. `SI_PREFIXES`
        # in stdlib humanize.cr) never get their value bound, and the
        # compiler's `type` getter raises a BUG on them.
        if value_type = type.value.try(&.type?)
          value_type_name = value_type.to_s
          type_info.parent_types << value_type_name unless type_info.parent_types.includes?(value_type_name)
        end
      end
    end

    private def index_type_defs(type : Crystal::NamedType, type_info : TypeInfo, type_name : String)
      if defs = type.defs
        defs.each_value do |items|
          items.each do |item|
            type_info.methods << method_info_for(item.def, owner: type_name)
            # `delegate` macro-expanded defs are passthroughs
            # (`def shift(*args, **kwargs); @array.shift(*args, **kwargs); end`)
            # carrying no return type: record them as delegates so the
            # query resolves the target's typed methods instead.
            if type_info.delegates[item.def.name.to_s]?.nil?
              if target = delegate_passthrough_target(item.def)
                type_info.delegates[item.def.name.to_s] = target
              end
            end
          end
        end
      end
    end

    private def index_type_macros(type : Crystal::ModuleType, type_info : TypeInfo, type_name : String)
      if macros = type.macros
        macros.each_value do |items|
          items.each do |macro_def|
            type_info.methods << method_info_for(macro_def, owner: type_name, is_macro: true)
          end
        end
      end
    end

    private def index_type_metaclass_defs(type : Crystal::NamedType, type_info : TypeInfo, type_name : String)
      if metaclass = type.metaclass
        if defs = metaclass.defs
          defs.each_value do |items|
            items.each do |item|
              type_info.methods << method_info_for(item.def, owner: type_name, class_method: true)
            end
          end
        end
      end
    end

    private def index_type_parents(type : Crystal::NamedType, type_info : TypeInfo)
      type.parents.try &.each do |parent_type|
        parent_name = parent_type.to_s
        type_info.parent_types << parent_name unless type_info.parent_types.includes?(parent_name)
      end
    end

    private def index_type_nested_types(type : Crystal::NamedType, type_info : TypeInfo)
      if nested_types = type.types?
        nested_types.each_value do |nested_type|
          type_info.subtypes << nested_type.to_s unless type_info.subtypes.includes?(nested_type.to_s)
          index_type(nested_type)
        end
      end
    end

    protected def method_info_for(definition : Crystal::Def | Crystal::Macro, *, owner : String, class_method = false, is_macro = false)
      args = definition.args.map do |arg|
        default_val = arg.responds_to?(:default_value) ? arg.default_value.try(&.to_s) : nil
        ArgInfo.new(name: arg.name.to_s, restriction: arg.restriction.try(&.to_s), default_value: default_val)
      end

      return_type = definition.responds_to?(:return_type) ? definition.return_type.try(&.to_s) : nil
      if return_type.nil? && definition.is_a?(Crystal::Def)
        # An untyped def: best-effort infer the return type from the body's
        # last expression (`@cache[entry]?.try &.[0]` → the hash value type)
        # so callers resolve before any compile. Bare names are resolved
        # against the merged index by the query afterwards.
        return_type = syntax_return_type_name(definition.body, ivars_for(owner), owner)
      end

      free_vars = definition.responds_to?(:free_vars) ? (definition.free_vars || [] of String).map(&.to_s) : [] of String
      block_restriction = definition.responds_to?(:block_arg) ? definition.block_arg.try(&.restriction.try(&.to_s)) : nil

      MethodInfo.new(
        name: definition.name.to_s,
        owner: owner,
        args: args,
        return_type: return_type,
        class_method: class_method,
        macro: is_macro,
        doc: definition.doc,
        location: definition.location,
        name_location: definition.responds_to?(:name_location) ? definition.name_location : nil,
        name_size: definition.name.to_s.size,
        free_vars: free_vars,
        block_restriction: block_restriction,
      )
    end

    private def ivars_for(type_name : String) : Hash(String, Array(String))
      @types[type_name]?.try(&.ivars) || {} of String => Array(String)
    end

    # Best-effort return type of an untyped def, from the body's last
    # expression. Conservative by design: anything it cannot type returns
    # nil, and the caller keeps no return type at all.
    private def syntax_return_type_name(node : Crystal::ASTNode, ivars : Hash(String, Array(String)), owner : String? = nil) : String?
      case node
      when Crystal::Expressions, Crystal::Return, Crystal::Assign, Crystal::If, Crystal::Var, Crystal::InstanceVar, Crystal::Call
        syntax_return_type_logic(node, ivars, owner)
      when Crystal::StringLiteral, Crystal::StringInterpolation, Crystal::NumberLiteral, Crystal::BoolLiteral, Crystal::CharLiteral, Crystal::SymbolLiteral, Crystal::NilLiteral, Crystal::RegexLiteral, Crystal::RangeLiteral, Crystal::TupleLiteral, Crystal::ArrayLiteral
        syntax_return_type_literal(node, ivars, owner)
      else
        nil
      end
    end

    private def syntax_return_type_logic(node : Crystal::ASTNode, ivars : Hash(String, Array(String)), owner : String?) : String?
      case node
      when Crystal::Expressions
        node.expressions.last?.try { |last| syntax_return_type_name(last, ivars, owner) }
      when Crystal::Return
        node.exp.try { |exp| syntax_return_type_name(exp, ivars, owner) } || "Nil"
      when Crystal::Assign
        syntax_return_type_name(node.value, ivars, owner)
      when Crystal::If
        syntax_return_type_logic_if(node, ivars, owner)
      when Crystal::Var
        node.name == "self" ? "self" : nil
      when Crystal::InstanceVar
        ivars[node.name]?.try(&.first?)
      when Crystal::Call
        syntax_call_return_type_name(node, ivars, owner)
      else
        nil
      end
    end

    private def syntax_return_type_logic_if(node : Crystal::If, ivars : Hash(String, Array(String)), owner : String?) : String?
      then_type = (t = node.then) ? syntax_return_type_name(t, ivars, owner) : nil
      else_type = (e = node.else) ? syntax_return_type_name(e, ivars, owner) : nil
      if then_type && else_type && then_type != else_type
        "#{then_type} | #{else_type}"
      else
        then_type || else_type
      end
    end

    private def syntax_return_type_literal(node : Crystal::ASTNode, ivars : Hash(String, Array(String)), owner : String?) : String?
      case node
      when Crystal::StringLiteral, Crystal::StringInterpolation then "String"
      when Crystal::NumberLiteral                               then number_literal_type_name(node)
      when Crystal::TupleLiteral                                then syntax_return_type_literal_tuple(node, ivars, owner)
      when Crystal::ArrayLiteral                                then syntax_return_type_literal_array(node, ivars, owner)
      when Crystal::BoolLiteral, Crystal::CharLiteral, Crystal::SymbolLiteral, Crystal::NilLiteral, Crystal::RegexLiteral, Crystal::RangeLiteral
        syntax_return_type_literal_simple(node)
      else
        nil
      end
    end

    private def syntax_return_type_literal_simple(node : Crystal::ASTNode) : String?
      case node
      when Crystal::BoolLiteral   then "Bool"
      when Crystal::CharLiteral   then "Char"
      when Crystal::SymbolLiteral then "Symbol"
      when Crystal::NilLiteral    then "Nil"
      when Crystal::RegexLiteral  then "Regex"
      when Crystal::RangeLiteral  then "Range"
      else
        nil
      end
    end

    private def syntax_return_type_literal_tuple(node : Crystal::TupleLiteral, ivars : Hash(String, Array(String)), owner : String?) : String?
      parts = node.elements.compact_map do |element|
        syntax_return_type_name(element, ivars, owner)
      end
      parts.empty? ? nil : "Tuple(#{parts.join(", ")})"
    end

    private def syntax_return_type_literal_array(node : Crystal::ArrayLiteral, ivars : Hash(String, Array(String)), owner : String?) : String?
      if of = node.of
        "Array(#{of})"
      elsif element = node.elements.first?
        element_type = syntax_return_type_name(element, ivars, owner)
        element_type ? "Array(#{element_type})" : "Array"
      else
        "Array"
      end
    end

    private def syntax_call_return_type_name(node : Crystal::Call, ivars : Hash(String, Array(String)), owner : String? = nil) : String?
      if (path = node.obj).is_a?(Crystal::Path)
        return path.to_s if node.name == "new" || node.name == path.to_s
        return nil
      end

      if type = syntax_call_return_type_special(node, ivars, owner)
        return type
      end

      if type = syntax_call_return_type_collection(node, ivars)
        return type
      end

      syntax_call_return_type_owner(node, owner)
    end

    private def syntax_call_return_type_owner(node : Crystal::Call, owner : String?) : String?
      return nil unless node.obj.nil? && owner
      return nil unless owner_type = @types[owner]?
      callee = owner_type.methods.find do |method_info|
        method_info.name == node.name && !method_info.class_method && method_info.return_type
      end
      callee.try(&.return_type)
    end

    private def syntax_call_return_type_special(node : Crystal::Call, ivars : Hash(String, Array(String)), owner : String?) : String?
      if node.name.in?("try", "tap", "itself", "not_nil!")
        receiver_type = (obj = node.obj) ? syntax_return_type_name(obj, ivars, owner) : nil
        return nil unless receiver_type
        if node.name == "try"
          if block = node.block
            return syntax_block_return_type_name(block, receiver_type)
          end
        end
        return receiver_type
      end

      if node.name.in?("has_key?", "empty?", "includes?", "nil?") && node.obj
        return "Bool"
      end

      nil
    end

    private def syntax_call_return_type_collection(node : Crystal::Call, ivars : Hash(String, Array(String))) : String?
      if node.name.in?("[]", "[]?", "fetch") && node.obj.is_a?(Crystal::InstanceVar)
        ivar_name = node.obj.as(Crystal::InstanceVar).name
        ivar_type = ivars[ivar_name]?.try(&.first?)
        return nil unless ivar_type
        if value_types = TypeUtils.hash_value_types(ivar_type)
          return value_types.join(" | ")
        elsif element_types = TypeUtils.array_element_types(ivar_type)
          return element_types.join(" | ")
        end
      end
      nil
    end

    private def number_literal_type_name(node : Crystal::NumberLiteral) : String?
      literal = node.to_s
      if literal.includes?('.') || literal.includes?('e') || literal.includes?('f')
        return literal.ends_with?("f32") ? "Float32" : "Float64"
      end

      %w[u8 u16 u32 u64 i8 i16 i32 i64].each do |suffix|
        if literal.ends_with?(suffix)
          type_name = suffix[0] == 'u' ? "UInt" : "Int"
          return type_name + suffix[1..]
        end
      end

      "Int32"
    end

    # `x.try &.[0]` — apply the block body (`__arg0[0]`) to the receiver's
    # type: a tuple's `[0]` yields its first element type.
    private def syntax_block_return_type_name(block : Crystal::Block, receiver_type : String) : String?
      body = block.body
      return nil unless body.is_a?(Crystal::Call)
      return nil unless body.name == "[]"

      index = body.args.first?.try(&.to_s)
      return nil unless index

      if tuple_types = TypeUtils.tuple_element_types(receiver_type)
        return tuple_types[0]?.try(&.join(" | ")) if index == "0"
        return tuple_types[1]?.try(&.join(" | ")) if index == "1"
      end

      nil
    end

    protected def kind_for(type : Crystal::NamedType)
      case type
      when Crystal::Const
        # A constant (`LSP::Log = ::Log.for(self)`) is a value, not a
        # type: the resolver resolves it through the recorded parent (the
        # value's type) instead of the class-method view.
        TypeKind::Constant
      when Crystal::AnnotationType
        TypeKind::Annotation
      when Crystal::AliasType
        TypeKind::Alias
      when Crystal::EnumType
        TypeKind::Enum
      when Crystal::LibType
        TypeKind::Lib
      when Crystal::ClassType
        type.struct? ? TypeKind::Struct : TypeKind::Class
      when Crystal::ModuleType
        TypeKind::Module
      else
        TypeKind::Unknown
      end
    end
  end
end
