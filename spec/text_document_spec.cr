require "./support/unwrap"
require "spec"
require "lsp/server"
require "../src/crystalino/text_document"

private def doc(contents : String)
  Crystalino::TextDocument.new(URI.parse("file:///tmp/test.cr"), nil, contents)
end

describe Crystalino::TextDocument do
  it "computes EOF position for empty contents" do
    document = doc("")

    document.eof_position.line.should eq(0)
    document.eof_position.character.should eq(0)
  end

  it "computes EOF position for contents ending with a newline" do
    document = doc("foo\nbar\n")

    document.eof_position.line.should eq(2)
    document.eof_position.character.should eq(0)
  end

  it "computes EOF position for contents without a trailing newline" do
    document = doc("foo\nbar")

    document.eof_position.line.should eq(1)
    document.eof_position.character.should eq(3)
  end

  it "preserves the exact line prefix during partial updates" do
    document = doc("foo\nbar\n")

    document.update_contents([
      {"", LSP::Range.new(
        start: LSP::Position.new(line: 0, character: 4),
        end: LSP::Position.new(line: 1, character: 0),
      )},
    ], version: 1)

    document.contents.should eq("foo\nbar\n")
  end

  it "updates the version on full document updates" do
    document = doc("foo\n")

    document.update_contents([
      {"bar\n", nil},
    ], version: 7)

    document.contents.should eq("bar\n")
    document.version.should eq(7)
  end

  it "clears stale pending changes when a full update arrives" do
    document = doc("foo\n")

    document.update_contents([
      {"bar\n", nil},
    ], version: 1)

    document.update_contents([
      {"baz", LSP::Range.new(
        start: LSP::Position.new(line: 0, character: 0),
        end: LSP::Position.new(line: 0, character: 3),
      )},
    ], version: 3)

    document.update_contents([
      {"qux\n", nil},
    ], version: 4)

    document.update_contents([
      {"zap", LSP::Range.new(
        start: LSP::Position.new(line: 0, character: 0),
        end: LSP::Position.new(line: 0, character: 3),
      )},
    ], version: 5)

    document.contents.should eq("zap\n")
    document.version.should eq(5)
  end

  it "tracks dirty state across edits and saves" do
    document = doc("foo\n")

    document.dirty?.should be_false

    document.update_contents([
      {"bar", LSP::Range.new(
        start: LSP::Position.new(line: 0, character: 0),
        end: LSP::Position.new(line: 0, character: 3),
      )},
    ], version: 1)

    document.dirty?.should be_true

    document.mark_saved

    document.dirty?.should be_false
  end

  it "applies multiple pending changes with identical versions in FIFO order" do
    document = doc("hello world\n")

    # Queue multiple changes for version 3 before version 2 arrives
    document.update_contents([
      {"goodbye", LSP::Range.new(
        start: LSP::Position.new(line: 0, character: 0),
        end: LSP::Position.new(line: 0, character: 5),
      )},
    ], version: 3)

    document.update_contents([
      {"friend", LSP::Range.new(
        start: LSP::Position.new(line: 0, character: 8),
        end: LSP::Position.new(line: 0, character: 13),
      )},
    ], version: 3)

    # Now deliver version 2
    document.update_contents([
      {"", LSP::Range.new(
        start: LSP::Position.new(line: 0, character: 5),
        end: LSP::Position.new(line: 0, character: 5),
      )},
    ], version: 2)

    document.contents.should eq("goodbye friend\n")
    document.version.should eq(3)
  end

  it "handles out-of-bounds column ranges without duplicating lines" do
    document = doc("abc\n")

    # Range with character offset beyond line length
    document.update_contents([
      {"def", LSP::Range.new(
        start: LSP::Position.new(line: 0, character: 3),
        end: LSP::Position.new(line: 0, character: 999),
      )},
    ], version: 1)

    document.contents.should eq("abcdef")
  end

  it "invalidates cached semantic tokens and folding ranges on edit" do
    document = doc("def foo\n  42\nend\n")
    document.cached_semantic_tokens = LSP::SemanticTokens.new(data: [1, 2, 3, 4, 5])
    document.cached_folding_ranges = [LSP::FoldingRange.new(start_line: 0, end_line: 2)]

    document.cached_semantic_tokens.should_not be_nil
    document.cached_folding_ranges.should_not be_nil

    document.update_contents([
      {"def bar\n  42\nend\n", nil},
    ], version: 1)

    document.cached_semantic_tokens.should be_nil
    document.cached_folding_ranges.should be_nil
  end
end
