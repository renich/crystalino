require "../support/unwrap"
require "spec"
require "../../src/crystalino/requires"
require "../../src/crystalino/main"
require "../../src/crystalino/lightweight/query"

private def build_lightweight_index(source : String)
  path = File.join(Dir.tempdir, "crystalino-lightweight-index-#{Random::Secure.hex(8)}.cr")
  File.write(path, source)

  begin
    Crystalino::EnvironmentConfig.run
    server = LSP::Server.new(IO::Memory.new, IO::Memory.new)
    result = Crystalino::Analysis.compile(
      server,
      URI.parse("file://#{path}"),
      lib_path: File.join(Dir.current, "lib"),
      top_level: true,
      ignore_diagnostics: true,
    )
    raise "expected top-level semantic result" unless result
    Crystalino::Lightweight::Index.from_program(result.program)
  ensure
    File.delete(path) if File.exists?(path)
  end
end

describe Crystalino::Lightweight::Index do
  it "provides query helpers over the lightweight index" do
    index = build_lightweight_index <<-CRYSTAL
      module Foo
        class Bar
          def baz(x : Int32) : String
            x.to_s
          end

          def self.make(name : String) : Foo::Bar
            new
          end
        end
      end

      def top_level(value : Bool) : Int32
        value ? 1 : 0
      end
    CRYSTAL

    query = Crystalino::Lightweight::Query.new(index)

    query.find_type("Foo::Bar").should_not be_nil
    query.subtypes_for("Foo").should contain("Foo::Bar")

    instance_methods = query.methods_for("Foo::Bar")
    instance_methods.map(&.name).should contain("baz")
    instance_methods.any?(&.macro).should be_false

    class_methods = query.methods_for("Foo::Bar", class_method: true)
    class_methods.map(&.name).should contain("make")

    query.top_level_methods.map(&.name).should contain("top_level")
  end

  it "indexes top-level methods and nested types from top-level semantic results" do
    index = build_lightweight_index <<-CRYSTAL
      module Foo
        class Bar
          def baz(x : Int32) : String
            x.to_s
          end

          def self.make(name : String) : Foo::Bar
            new
          end
        end
      end

      def top_level(value : Bool) : Int32
        value ? 1 : 0
      end
    CRYSTAL

    foo = index.types["Foo"]?
    foo.should_not be_nil
    foo.unwrap!.kind.should eq(Crystalino::Lightweight::TypeKind::Module)
    foo.unwrap!.subtypes.should contain("Foo::Bar")

    bar = index.types["Foo::Bar"]?
    bar.should_not be_nil
    bar = bar.unwrap!
    bar.kind.should eq(Crystalino::Lightweight::TypeKind::Class)

    baz = bar.methods.find { |method| method.name == "baz" && !method.class_method && !method.macro }
    baz.should_not be_nil
    baz = baz.unwrap!
    baz.return_type.should eq("String")
    baz.args.map(&.restriction).should eq(["Int32"])

    make = bar.methods.find { |method| method.name == "make" && method.class_method }
    make.should_not be_nil
    make = make.unwrap!
    make.return_type.should eq("Foo::Bar")
    make.args.map(&.restriction).should eq(["String"])

    top_level = index.top_level_methods.find(&.name.==("top_level"))
    top_level.should_not be_nil
    top_level.unwrap!.return_type.should eq("Int32")
    top_level.unwrap!.args.map(&.restriction).should eq(["Bool"])
  end

  it "indexes nested types from single-member source bodies" do
    index = Crystalino::Lightweight::Index.from_source(<<-CRYSTAL).should_not be_nil
      class Foo
        class Inner; end
      end
      class WithMethods
        def bar : Int32
          1
        end
      end
    CRYSTAL

    foo = index.types["Foo"]?
    foo.should_not be_nil
    foo.unwrap!.subtypes.should contain("Foo::Inner")
    index.types["Foo::Inner"]?.should_not be_nil

    with_methods = index.types["WithMethods"]?
    with_methods.should_not be_nil
    with_methods.unwrap!.methods.map(&.name).should contain("bar")
  end

  it "indexes accessor macros from source bodies" do
    index = Crystalino::Lightweight::Index.from_source(<<-CRYSTAL).should_not be_nil
      class User
        getter name : String
        property age : Int32
        getter? active : Bool
        class_property @@count : Int32
        setter raw
      end
    CRYSTAL

    user = index.types["User"]?.should_not be_nil

    getter = user.methods.find { |method_node| method_node.name == "name" && !method_node.class_method }
    getter.should_not be_nil
    getter.unwrap!.return_type.should eq("String")
    getter.unwrap!.args.should be_empty

    user.methods.map(&.name).should contain("age")
    user.methods.map(&.name).should contain("age=")
    user.methods.map(&.name).should contain("active?")

    class_getter = user.methods.find { |method_node| method_node.name == "count" && method_node.class_method }
    class_getter.should_not be_nil
    class_getter.unwrap!.return_type.should eq("Int32")

    setter = user.methods.find(&.name.==("raw="))
    setter.should_not be_nil
    setter.unwrap!.args.map(&.name).should eq(["value"])
  end

  it "indexes classes defined in macro bodies" do
    index = Crystalino::Lightweight::Index.from_source(<<-CRYSTAL).should_not be_nil
      module LSP
        macro finished
          class HoverRequest < RequestMessage(Hover?)
            property params : HoverParams
          end
        end
      end
    CRYSTAL

    hover = index.types["LSP::HoverRequest"]?.should_not be_nil
    hover.methods.map(&.name).should contain("params")
    hover.parent_types.should contain("RequestMessage(Hover | ::Nil)")
  end

  it "types accessor initializers from their of-clause" do
    index = Crystalino::Lightweight::Index.from_source(<<-CRYSTAL).should_not be_nil
      class Store
        getter entries = {} of String => Int32
        getter items = [] of String
        getter count = 42
      end
    CRYSTAL

    store = index.types["Store"]?.should_not be_nil

    entries = store.methods.find(&.name.==("entries"))
    entries.should_not be_nil
    entries.unwrap!.return_type.should eq("Hash(String, Int32)")
    store.ivars["@entries"]?.should eq(["Hash(String, Int32)"])

    items = store.methods.find(&.name.==("items"))
    items.should_not be_nil
    items.unwrap!.return_type.should eq("Array(String)")

    count = store.methods.find(&.name.==("count"))
    count.should_not be_nil
    count.unwrap!.return_type.should be_nil
  end

  it "indexes private and protected defs from source bodies" do
    index = Crystalino::Lightweight::Index.from_source(<<-CRYSTAL).should_not be_nil
      class User
        private def secret : String
          "s"
        end

        protected def helper(name : String) : Int32
          name.size
        end
      end
    CRYSTAL

    user = index.types["User"].should_not be_nil

    secret = user.methods.find(&.name.==("secret"))
    secret.should_not be_nil
    secret.unwrap!.return_type.should eq("String")

    helper = user.methods.find(&.name.==("helper"))
    helper.should_not be_nil
    helper.unwrap!.args.map(&.name).should eq(["name"])
  end

  it "indexes records as types with field getters from source bodies" do
    index = Crystalino::Lightweight::Index.from_source(<<-CRYSTAL).should_not be_nil
      module Compiler
        record Result, program : Program, node : ASTNode
      end
    CRYSTAL

    result = index.types["Compiler::Result"]?.should_not be_nil
    result.kind.should eq(Crystalino::Lightweight::TypeKind::Struct)

    node = result.methods.find(&.name.==("node"))
    node.should_not be_nil
    node.unwrap!.return_type.should eq("ASTNode")
    node.unwrap!.args.should be_empty

    program = result.methods.find(&.name.==("program"))
    program.should_not be_nil
    program.unwrap!.return_type.should eq("Program")
  end

  it "indexes aliases inside module and class bodies" do
    index = Crystalino::Lightweight::Index.from_source(<<-CRYSTAL).should_not be_nil
      module Dispatcher
        alias Handler = Proc(String, URI, String)

        class Registry
          alias Item = Hash(String, Int32)
        end
      end
    CRYSTAL

    handler = index.types["Dispatcher::Handler"]?.should_not be_nil
    handler.kind.should eq(Crystalino::Lightweight::TypeKind::Alias)
    handler.parent_types.should contain("Proc(String, URI, String)")

    item = index.types["Dispatcher::Registry::Item"]?.should_not be_nil
    item.parent_types.should contain("Hash(String, Int32)")
  end

  it "merges split definitions into a union of methods, parents and subtypes" do
    index_a = Crystalino::Lightweight::Index.from_source(<<-CRYSTAL).should_not be_nil
      module Crystal
        class ASTNode
          def at : Location?
            nil
          end

          def no_returns? : Bool
            false
          end
        end
      end
    CRYSTAL

    index_b = Crystalino::Lightweight::Index.from_source(<<-CRYSTAL).should_not be_nil
      module Crystal
        class ASTNode
          def accept(visitor)
          end

          def accept_children(visitor)
          end
        end
      end
    CRYSTAL

    merged = Crystalino::Lightweight::Index.merge([index_a, index_b])
    ast_node = merged.types["Crystal::ASTNode"]?.should_not be_nil

    ast_node.methods.map(&.name).should contain("at")
    ast_node.methods.map(&.name).should contain("accept")
    ast_node.methods.map(&.name).should contain("accept_children")
  end

  it "records superclasses and includes as parents from source bodies" do
    index = Crystalino::Lightweight::Index.from_source(<<-CRYSTAL).should_not be_nil
      module Mixin
      end

      class Base
      end

      class Sub < Base
        include Mixin
      end
    CRYSTAL

    sub = index.types["Sub"]?.should_not be_nil
    sub.parent_types.should contain("Base")
    sub.parent_types.should contain("Mixin")
  end

  it "records the implicit Reference superclass for superclass-less classes" do
    index = Crystalino::Lightweight::Index.from_source(<<-CRYSTAL).should_not be_nil
      class Plain
      end

      record Pair, left : Int32, right : Int32
    CRYSTAL

    plain = index.types["Plain"]?.should_not be_nil
    plain.parent_types.should contain("Reference")

    pair = index.types["Pair"]?.should_not be_nil
    pair.parent_types.should_not contain("Reference")
  end

  it "synthesizes a class-method new from initialize" do
    index = Crystalino::Lightweight::Index.from_source(<<-CRYSTAL).should_not be_nil
      class WithArgs
        def initialize(name : String, count : Int32)
        end
      end

      class Bare
      end
    CRYSTAL

    with_args = index.types["WithArgs"]?.should_not be_nil
    new_method = with_args.methods.find { |method_node| method_node.class_method && method_node.name == "new" }.should_not be_nil
    new_method.unwrap!.args.map(&.name).should eq(["name", "count"])
    new_method.unwrap!.args.map(&.restriction).should eq(["String", "Int32"])
    new_method.unwrap!.return_type.should eq("WithArgs")

    bare_new = (index.types["Bare"]? || raise "Expected Bare type not to be nil").methods.find { |method_node| method_node.class_method && method_node.name == "new" }
    bare_new.should_not be_nil
    bare_new.unwrap!.args.should be_empty
  end

  it "records getter-backed ivars with their restrictions" do
    index = Crystalino::Lightweight::Index.from_source(<<-CRYSTAL).should_not be_nil
      class User
        getter root_uri : URI?
        property age : Int32
      end
    CRYSTAL

    user = index.types["User"]?.should_not be_nil
    # `URI?` parses as a union whose to_s expands to `URI | ::Nil`.
    user.ivars["@root_uri"].should eq(["URI | ::Nil"])
    user.ivars["@age"].should eq(["Int32"])
  end

  it "infers the return type of untyped defs from the body's last expression" do
    index = Crystalino::Lightweight::Index.from_source(<<-CRYSTAL).should_not be_nil
      class Store
        @cache : Hash(String, {Crystal::Compiler::Result?, Time::Instant?}) = {} of String => {Crystal::Compiler::Result?, Time::Instant?}

        def get(entry : String)
          @cache[entry]?.try &.[0]
        end

        def name
          "hello"
        end

        def count
          42
        end

        def empty
          @cache.empty?
        end

        def make
          Foo.new
        end
      end
    CRYSTAL

    store = index.types["Store"]?.should_not be_nil

    get = store.methods.find(&.name.==("get")).should_not be_nil
    get.unwrap!.return_type.should eq("Crystal::Compiler::Result | ::Nil")

    name = store.methods.find(&.name.==("name")).should_not be_nil
    name.unwrap!.return_type.should eq("String")

    count = store.methods.find(&.name.==("count")).should_not be_nil
    count.unwrap!.return_type.should eq("Int32")

    empty = store.methods.find(&.name.==("empty")).should_not be_nil
    empty.unwrap!.return_type.should eq("Bool")

    make = store.methods.find(&.name.==("make")).should_not be_nil
    make.unwrap!.return_type.should eq("Foo")
  end
end
