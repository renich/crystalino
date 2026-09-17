require "../support/unwrap"
require "spec"
require "../../src/crystalino/requires"
require "../../src/crystalino/main"
require "../../src/crystalino/lightweight/signature_help"

private def build_syntax_sig_query(defs : String)
  index = Crystalino::Lightweight::Index.from_source(defs)
  raise "expected syntax index" unless index
  Crystalino::Lightweight::Query.new(index, secondary: prelude_index)
end

private def prelude_index : Crystalino::Lightweight::Index
  Crystalino::Lightweight::PreludeIndex.ensure_loaded
  until index = Crystalino::Lightweight::PreludeIndex.get
    sleep 50.milliseconds
  end
  index
end

describe Crystalino::Lightweight::SignatureHelp do
  it "provides signature help for top-level methods" do
    defs = <<-CRYSTAL
      # Greets a user.
      def greet(name : String, times : Int32 = 1) : Nil
        times.times { puts name }
      end
    CRYSTAL

    query = build_syntax_sig_query(defs)
    buffer = "greet("

    sig_help = Crystalino::Lightweight::SignatureHelp.signature_help(
      buffer,
      0,
      6, # right after '('
      query
    )

    sig_help.should_not be_nil
    help = sig_help.unwrap!
    help.signatures.size.should be >= 1
    sig = help.signatures.first
    sig.label.should contain("greet(name : String, times : Int32 = 1)")
    sig.parameters.unwrap!.size.should eq(2)
    sig.parameters.unwrap![0].label.should eq("name : String")
    sig.parameters.unwrap![1].label.should eq("times : Int32 = 1")
    help.active_parameter.should eq(0)
    sig.documentation.unwrap!.as(LSP::MarkupContent).value.should contain("Greets a user.")
  end

  it "advances active parameter after commas" do
    defs = <<-CRYSTAL
      def calculate(x : Int32, y : Int32, label : String) : Int32
        x + y
      end
    CRYSTAL

    query = build_syntax_sig_query(defs)
    buffer = "calculate(10, "

    sig_help = Crystalino::Lightweight::SignatureHelp.signature_help(
      buffer,
      0,
      buffer.size, # right after ", "
      query
    )

    sig_help.should_not be_nil
    help = sig_help.unwrap!
    help.active_parameter.should eq(1)
  end

  it "provides signature help for instance method calls" do
    defs = <<-CRYSTAL
      class Account
        # Updates balance.
        def deposit(amount : Float64, note : String = "") : Bool
          true
        end
      end
    CRYSTAL

    query = build_syntax_sig_query(defs)
    buffer = <<-CRYSTAL
      acc = Account.new
      acc.deposit(
    CRYSTAL

    lines = buffer.lines
    target_line = lines.index!(&.strip.starts_with?("acc.deposit("))
    sig_help = Crystalino::Lightweight::SignatureHelp.signature_help(
      buffer,
      target_line,
      lines[target_line].size,
      query
    )

    sig_help.should_not be_nil
    help = sig_help.unwrap!
    sig = help.signatures.first
    sig.label.should contain("deposit(amount : Float64, note : String = \"\")")
    help.active_parameter.should eq(0)
    sig.documentation.unwrap!.as(LSP::MarkupContent).value.should contain("Updates balance.")
  end

  it "provides signature help for class methods and constructors" do
    defs = <<-CRYSTAL
      class Server
        def initialize(@port : Int32, @host : String = "localhost")
        end
      end
    CRYSTAL

    query = build_syntax_sig_query(defs)
    buffer = "Server.new("

    sig_help = Crystalino::Lightweight::SignatureHelp.signature_help(
      buffer,
      0,
      buffer.size,
      query
    )

    sig_help.should_not be_nil
    help = sig_help.unwrap!
    sig = help.signatures.first
    sig.label.should contain("new(port : Int32, host : String = \"localhost\")")
    help.active_parameter.should eq(0)
  end

  it "handles nested method calls correctly" do
    defs = <<-CRYSTAL
      def inner(a : Int32, b : Int32) : Int32
        a + b
      end

      def outer(first : Int32, second : String) : Nil
      end
    CRYSTAL

    query = build_syntax_sig_query(defs)
    buffer = "outer(inner(1, 2), "

    # Test 1: Cursor inside inner call at second argument: `outer(inner(1, |2), `
    inner_comma_col = buffer.index!("inner(1,") + 8
    inner_help = Crystalino::Lightweight::SignatureHelp.signature_help(
      buffer,
      0,
      inner_comma_col,
      query
    )
    inner_help.should_not be_nil
    inner_help.unwrap!.signatures.first.label.should contain("inner(a : Int32, b : Int32)")
    inner_help.unwrap!.active_parameter.should eq(1)

    # Test 2: Cursor after inner call in outer call: `outer(inner(1, 2), |`
    outer_end_col = buffer.size
    outer_help = Crystalino::Lightweight::SignatureHelp.signature_help(
      buffer,
      0,
      outer_end_col,
      query
    )
    outer_help.should_not be_nil
    outer_help.unwrap!.signatures.first.label.should contain("outer(first : Int32, second : String)")
    outer_help.unwrap!.active_parameter.should eq(1)
  end

  it "ignores commas inside string literals" do
    defs = <<-CRYSTAL
      def send_message(recipient : String, message : String) : Bool
        true
      end
    CRYSTAL

    query = build_syntax_sig_query(defs)
    buffer = "send_message(\"Doe, Jane, Dr.\", "

    sig_help = Crystalino::Lightweight::SignatureHelp.signature_help(
      buffer,
      0,
      buffer.size,
      query
    )

    sig_help.should_not be_nil
    help = sig_help.unwrap!
    help.active_parameter.should eq(1)
  end

  it "returns nil inside comments" do
    defs = <<-CRYSTAL
      def hello(name : String)
      end
    CRYSTAL

    query = build_syntax_sig_query(defs)
    buffer = "# hello("

    sig_help = Crystalino::Lightweight::SignatureHelp.signature_help(
      buffer,
      0,
      buffer.size,
      query
    )

    sig_help.should be_nil
  end

  it "returns nil for keywords like if or def" do
    defs = <<-CRYSTAL
      def dummy
      end
    CRYSTAL

    query = build_syntax_sig_query(defs)

    sig_help_if = Crystalino::Lightweight::SignatureHelp.signature_help("if (true", 0, 8, query)
    sig_help_if.should be_nil

    sig_help_def = Crystalino::Lightweight::SignatureHelp.signature_help("def foo(", 0, 8, query)
    sig_help_def.should be_nil
  end
end
