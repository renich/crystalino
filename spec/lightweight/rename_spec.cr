require "../support/unwrap"
require "spec"
require "../../src/crystalino/requires"
require "../../src/crystalino/main"
require "../../src/crystalino/lightweight/rename"

describe Crystalino::Lightweight::Rename do
  it "prepares rename on a valid identifier" do
    source = <<-CRYSTAL
    def calculate(value : Int32)
      total = value * 2
      total
    end
    CRYSTAL

    # Cursor on 'total' in 'total = value * 2' (line 1, character 2)
    prep = Crystalino::Lightweight::Rename.prepare_rename(source, 1, 2)
    prep.should_not be_nil
    res = prep.unwrap!
    res.placeholder.should eq("total")
    res.range.start.line.should eq(1)
    res.range.start.character.should eq(2)
    res.range.end.character.should eq(7)
  end

  it "returns nil on keywords and whitespace" do
    source = <<-CRYSTAL
    def calculate
      1
    end
    CRYSTAL

    # Cursor on 'def' (line 0, col 0)
    Crystalino::Lightweight::Rename.prepare_rename(source, 0, 0).should be_nil

    # Cursor on whitespace (line 0, col 3)
    Crystalino::Lightweight::Rename.prepare_rename(source, 0, 3).should be_nil
  end

  it "renames local variable strictly within enclosing method scope" do
    source = <<-CRYSTAL
    def calculate(x)
      total = x + 1
      total += 2
      total
    end

    def other
      total = 100
      total
    end
    CRYSTAL

    uri = URI.parse("file:///project/calc.cr")
    # Rename 'total' in calculate to 'sum' (line 1, character 2)
    edit = Crystalino::Lightweight::Rename.rename(source, uri, 1, 2, "sum")
    edit.should_not be_nil
    ws_edit = edit.unwrap!
    changes = ws_edit.changes[uri.to_s]
    changes.size.should eq(3)

    # All 3 changes must be within lines 1 to 4
    changes.each do |change|
      change.new_text.should eq("sum")
      change.range.start.line.should be >= 1
      change.range.start.line.should be <= 3
    end
  end

  it "renames instance variables ensuring @ prefix is preserved" do
    source = <<-CRYSTAL
    class Counter
      @count = 0

      def inc
        @count += 1
      end
    end
    CRYSTAL

    uri = URI.parse("file:///project/counter.cr")
    # Rename '@count' with 'tally' (without @ in input)
    edit = Crystalino::Lightweight::Rename.rename(source, uri, 1, 2, "tally")
    edit.should_not be_nil
    ws_edit = edit.unwrap!
    changes = ws_edit.changes[uri.to_s]
    changes.size.should eq(2)

    changes.each do |change|
      change.new_text.should eq("@tally")
    end
  end

  it "rejects invalid identifiers" do
    source = <<-CRYSTAL
    def foo
      x = 1
      x
    end
    CRYSTAL

    uri = URI.parse("file:///project/foo.cr")
    # Invalid names
    Crystalino::Lightweight::Rename.rename(source, uri, 1, 2, "123invalid").should be_nil
    Crystalino::Lightweight::Rename.rename(source, uri, 1, 2, "").should be_nil
    Crystalino::Lightweight::Rename.rename(source, uri, 1, 2, "bad-name").should be_nil
  end

  it "returns nil inside comments and string literals" do
    source = <<-CRYSTAL
    # This is a comment with total
    msg = "total string"
    CRYSTAL

    Crystalino::Lightweight::Rename.prepare_rename(source, 0, 26).should be_nil
    Crystalino::Lightweight::Rename.prepare_rename(source, 1, 8).should be_nil
  end
end
