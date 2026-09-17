require "../support/unwrap"
require "spec"
require "../../src/crystalino/requires"
require "../../src/crystalino/main"
require "../../src/crystalino/lightweight/folding_range"

describe Crystalino::Lightweight::FoldingRange do
  it "folds classes, modules, and methods" do
    source = <<-CRYSTAL
    module MathUtils
      class Calculator
        def add(a, b)
          a + b
        end

        def multiply(a, b)
          a * b
        end
      end
    end
    CRYSTAL

    ranges = Crystalino::Lightweight::FoldingRange.folding_ranges(source)
    ranges.should_not be_nil
    list = ranges.unwrap!
    list.size.should be >= 4

    # module MathUtils
    list.any? { |range| range.start_line == 0 && range.end_line == 10 }.should be_true
    # class Calculator
    list.any? { |range| range.start_line == 1 && range.end_line == 9 }.should be_true
    # def add
    list.any? { |range| range.start_line == 2 && range.end_line == 4 }.should be_true
    # def multiply
    list.any? { |range| range.start_line == 6 && range.end_line == 8 }.should be_true
  end

  it "folds multiline blocks and control flow" do
    source = <<-CRYSTAL
    def process(items)
      items.each do |item|
        if item > 0
          puts item
        else
          puts -item
        end
      end
    end
    CRYSTAL

    ranges = Crystalino::Lightweight::FoldingRange.folding_ranges(source)
    ranges.should_not be_nil
    list = ranges.unwrap!

    # def process
    list.any? { |range| range.start_line == 0 && range.end_line == 8 }.should be_true
    # each do
    list.any? { |range| range.start_line == 1 && range.end_line == 7 }.should be_true
    # if
    list.any? { |range| range.start_line == 2 && range.end_line == 6 }.should be_true
  end

  it "folds consecutive comment blocks with comment kind" do
    source = <<-CRYSTAL
    # This is line 1
    # This is line 2
    # This is line 3
    def foo
      1
    end
    CRYSTAL

    ranges = Crystalino::Lightweight::FoldingRange.folding_ranges(source)
    ranges.should_not be_nil
    list = ranges.unwrap!

    comment_fold = list.find { |range| range.kind == LSP::FoldingRangeKind::Comment }
    comment_fold.should_not be_nil
    fold = comment_fold.unwrap!
    fold.start_line.should eq(0)
    fold.end_line.should eq(2)
  end

  it "folds consecutive require statements with imports kind" do
    source = <<-CRYSTAL
    require "json"
    require "http"
    require "uri"

    puts "ready"
    CRYSTAL

    ranges = Crystalino::Lightweight::FoldingRange.folding_ranges(source)
    ranges.should_not be_nil
    list = ranges.unwrap!

    imports_fold = list.find { |range| range.kind == LSP::FoldingRangeKind::Imports }
    imports_fold.should_not be_nil
    fold = imports_fold.unwrap!
    fold.start_line.should eq(0)
    fold.end_line.should eq(2)
  end

  it "folds multiline strings and heredocs" do
    source = <<-CRYSTAL
    text = <<-TEXT
    First line
    Second line
    Third line
    TEXT
    CRYSTAL

    ranges = Crystalino::Lightweight::FoldingRange.folding_ranges(source)
    ranges.should_not be_nil
    list = ranges.unwrap!

    list.any? { |range| range.start_line == 0 && range.end_line == 4 }.should be_true
  end

  it "folds multiline array and hash literals" do
    source = <<-CRYSTAL
    config = {
      host: "localhost",
      port: 8080,
      active: true,
    }
    CRYSTAL

    ranges = Crystalino::Lightweight::FoldingRange.folding_ranges(source)
    ranges.should_not be_nil
    list = ranges.unwrap!

    list.any? { |range| range.start_line == 0 && range.end_line == 4 }.should be_true
  end

  it "returns nil on empty source" do
    Crystalino::Lightweight::FoldingRange.folding_ranges("").should be_nil
  end

  it "falls back to indentation folding on incomplete source" do
    source = <<-CRYSTAL
    def broken(x
      if x > 0
        puts x
      end
    end
    CRYSTAL

    ranges = Crystalino::Lightweight::FoldingRange.folding_ranges(source)
    ranges.should_not be_nil
    list = ranges.unwrap!
    list.should_not be_empty
  end
end
