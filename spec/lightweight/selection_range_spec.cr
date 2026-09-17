require "../support/unwrap"
require "spec"
require "../../src/crystalino/requires"
require "../../src/crystalino/main"
require "../../src/crystalino/lightweight/selection_range"

describe Crystalino::Lightweight::SelectionRange do
  it "builds an expanding selection hierarchy from innermost node to whole document" do
    source = <<-CRYSTAL
    class Calculator
      def add(a, b)
        total = a + b
        total
      end
    end
    CRYSTAL

    # Cursor on 'b' in 'total = a + b' (line 2, col 16)
    pos = LSP::Position.new(line: 2, character: 16)
    ranges = Crystalino::Lightweight::SelectionRange.selection_ranges(source, [pos])
    ranges.should_not be_nil
    list = ranges.unwrap!
    list.size.should eq(1)

    level0 = list.first
    # Innermost is 'b' (character 16 to 17)
    level0.range.start.line.should eq(2)
    level0.range.start.character.should be <= 16
    level0.range.end.character.should be >= 17

    # Expanding parent should exist
    level1 = level0.parent
    level1.should_not be_nil
    p1 = level1.unwrap!
    p1.range.start.line.should eq(2)

    # Climb to outermost document range
    curr = level0
    depth = 0
    while parent = curr.parent
      curr = parent
      depth += 1
    end

    # Outermost encompasses whole document
    depth.should be >= 3
    curr.range.start.line.should eq(0)
    curr.range.end.line.should eq(5)
  end

  it "handles multiple positions for multi-cursor selection" do
    source = <<-CRYSTAL
    def first
      1
    end

    def second
      2
    end
    CRYSTAL

    pos1 = LSP::Position.new(line: 1, character: 2)
    pos2 = LSP::Position.new(line: 5, character: 2)

    ranges = Crystalino::Lightweight::SelectionRange.selection_ranges(source, [pos1, pos2])
    ranges.should_not be_nil
    list = ranges.unwrap!
    list.size.should eq(2)

    list[0].range.start.line.should eq(1)
    list[1].range.start.line.should eq(5)
  end

  it "returns fallback ranges when cursor is on whitespace" do
    source = <<-CRYSTAL
    def foo
      x = 1
    end
    CRYSTAL

    pos = LSP::Position.new(line: 0, character: 7)
    ranges = Crystalino::Lightweight::SelectionRange.selection_ranges(source, [pos])
    ranges.should_not be_nil
    list = ranges.unwrap!
    list.size.should eq(1)

    item = list.first
    item.range.start.line.should eq(0)
  end

  it "returns nil for empty source or empty positions" do
    pos = LSP::Position.new(line: 0, character: 0)
    Crystalino::Lightweight::SelectionRange.selection_ranges("", [pos]).should be_nil
    Crystalino::Lightweight::SelectionRange.selection_ranges("def foo; end", [] of LSP::Position).should be_nil
  end

  it "handles incomplete / broken syntax gracefully" do
    source = <<-CRYSTAL
    def broken(a,
      total = a + 1
    CRYSTAL

    pos = LSP::Position.new(line: 1, character: 4)
    ranges = Crystalino::Lightweight::SelectionRange.selection_ranges(source, [pos])
    ranges.should_not be_nil
    list = ranges.unwrap!
    list.size.should eq(1)
  end
end
