require "../support/unwrap"
require "spec"
require "../../src/crystalline/requires"
require "../../src/crystalline/main"
require "../../src/crystalline/lightweight/document_highlight"

describe Crystalline::Lightweight::DocumentHighlight do
  it "highlights local variable reads and writes scoped to enclosing def" do
    source = <<-CRYSTAL
    def calculate(x, y)
      total = x + y
      total += 10
      puts total
      total
    end

    def other(total)
      total * 2
    end
    CRYSTAL

    # Cursor on 'total' in 'total = x + y' (line 1, col 2 in 0-indexed)
    highlights = Crystalline::Lightweight::DocumentHighlight.highlights(source, 1, 2)
    highlights.should_not be_nil
    list = highlights.unwrap!
    list.size.should eq(4)

    # total = x + y (Write)
    list[0].range.start.line.should eq(1)
    list[0].kind.should eq(LSP::DocumentHighlightKind::Write)

    # total += 10 (Write)
    list[1].range.start.line.should eq(2)
    list[1].kind.should eq(LSP::DocumentHighlightKind::Write)

    # puts total (Read)
    list[2].range.start.line.should eq(3)
    list[2].kind.should eq(LSP::DocumentHighlightKind::Read)

    # total (Read)
    list[3].range.start.line.should eq(4)
    list[3].kind.should eq(LSP::DocumentHighlightKind::Read)
  end

  it "highlights method parameters as writes and references as reads" do
    source = <<-CRYSTAL
    def process(count : Int32)
      double = count * 2
      double + count
    end
    CRYSTAL

    # Cursor on 'count' in parameter definition (line 0, col 14)
    highlights = Crystalline::Lightweight::DocumentHighlight.highlights(source, 0, 14)
    highlights.should_not be_nil
    list = highlights.unwrap!
    list.size.should eq(3)

    # parameter definition is Write
    list[0].range.start.line.should eq(0)
    list[0].kind.should eq(LSP::DocumentHighlightKind::Write)

    # count * 2 is Read
    list[1].range.start.line.should eq(1)
    list[1].kind.should eq(LSP::DocumentHighlightKind::Read)

    # + count is Read
    list[2].range.start.line.should eq(2)
    list[2].kind.should eq(LSP::DocumentHighlightKind::Read)
  end

  it "highlights instance variables across enclosing class" do
    source = <<-CRYSTAL
    class Counter
      @val = 0

      def inc
        @val += 1
      end

      def get
        @val
      end
    end
    CRYSTAL

    # Cursor on '@val' in '@val = 0' (line 1, col 2)
    highlights = Crystalline::Lightweight::DocumentHighlight.highlights(source, 1, 2)
    highlights.should_not be_nil
    list = highlights.unwrap!
    list.size.should eq(3)

    # @val = 0 (Write)
    list[0].range.start.line.should eq(1)
    list[0].kind.should eq(LSP::DocumentHighlightKind::Write)

    # @val += 1 (Write)
    list[1].range.start.line.should eq(4)
    list[1].kind.should eq(LSP::DocumentHighlightKind::Write)

    # @val in get (Read)
    list[2].range.start.line.should eq(8)
    list[2].kind.should eq(LSP::DocumentHighlightKind::Read)
  end

  it "highlights class variables" do
    source = <<-CRYSTAL
    class App
      @@active = false

      def self.start
        @@active = true
      end

      def self.active?
        @@active
      end
    end
    CRYSTAL

    # Cursor on '@@active' (line 1, col 2)
    highlights = Crystalline::Lightweight::DocumentHighlight.highlights(source, 1, 2)
    highlights.should_not be_nil
    list = highlights.unwrap!
    list.size.should eq(3)
    list[0].kind.should eq(LSP::DocumentHighlightKind::Write)
    list[1].kind.should eq(LSP::DocumentHighlightKind::Write)
    list[2].kind.should eq(LSP::DocumentHighlightKind::Read)
  end

  it "highlights method definitions and calls" do
    source = <<-CRYSTAL
    def greet(name)
      "Hello " + name
    end

    greet("Alice")
    greet("Bob")
    CRYSTAL

    # Cursor on 'greet' call (line 4, col 2)
    highlights = Crystalline::Lightweight::DocumentHighlight.highlights(source, 4, 2)
    highlights.should_not be_nil
    list = highlights.unwrap!
    list.size.should eq(3)

    list[0].range.start.line.should eq(0)
    list[0].kind.should eq(LSP::DocumentHighlightKind::Write)

    list[1].range.start.line.should eq(4)
    list[1].kind.should eq(LSP::DocumentHighlightKind::Read)

    list[2].range.start.line.should eq(5)
    list[2].kind.should eq(LSP::DocumentHighlightKind::Read)
  end

  it "highlights types and constants" do
    source = <<-CRYSTAL
    class Worker
      def run
      end
    end

    w = Worker.new
    w.run
    CRYSTAL

    # Cursor on 'Worker' in 'Worker.new' (line 5, col 4)
    highlights = Crystalline::Lightweight::DocumentHighlight.highlights(source, 5, 4)
    highlights.should_not be_nil
    list = highlights.unwrap!
    list.size.should eq(2)

    list[0].range.start.line.should eq(0)
    list[0].kind.should eq(LSP::DocumentHighlightKind::Write)

    list[1].range.start.line.should eq(5)
    list[1].kind.should eq(LSP::DocumentHighlightKind::Read)
  end

  it "returns nil when cursor is on whitespace or empty line" do
    source = <<-CRYSTAL
    def   foo
      x = 1
    end
    CRYSTAL

    # Space between 'def' and 'foo'
    Crystalline::Lightweight::DocumentHighlight.highlights(source, 0, 4).should be_nil
    # Out-of-bounds line
    Crystalline::Lightweight::DocumentHighlight.highlights(source, 4, 0).should be_nil
  end

  it "falls back to textual highlighting when syntax has typing errors" do
    source = <<-CRYSTAL
    foo = 1
    foo.
    puts foo
    CRYSTAL

    # Cursor on 'foo' at line 0, col 1
    highlights = Crystalline::Lightweight::DocumentHighlight.highlights(source, 0, 1)
    highlights.should_not be_nil
    list = highlights.unwrap!
    list.size.should be >= 2
  end
end
