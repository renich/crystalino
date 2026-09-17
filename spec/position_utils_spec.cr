require "./support/unwrap"
require "spec"
require "../src/crystalino/position_utils"

# "aé😀bc": a = 1 code unit, é = 1, 😀 (astral) = 2, b = 1, c = 1.
LINE = "aé😀bc"

describe Crystalino::PositionUtils do
  describe ".utf16_to_char_index" do
    it "is the identity on ascii lines" do
      Crystalino::PositionUtils.utf16_to_char_index("abc", 2).should eq(2)
    end

    it "maps bmp characters one-to-one" do
      Crystalino::PositionUtils.utf16_to_char_index(LINE, 2).should eq(2)
    end

    it "accounts for astral characters" do
      Crystalino::PositionUtils.utf16_to_char_index(LINE, 4).should eq(3)
    end

    it "clamps past the end of the line" do
      Crystalino::PositionUtils.utf16_to_char_index(LINE, 99).should eq(5)
    end
  end

  describe ".char_to_utf16_index" do
    it "is the identity on ascii lines" do
      Crystalino::PositionUtils.char_to_utf16_index("abc", 2).should eq(2)
    end

    it "accounts for astral characters" do
      Crystalino::PositionUtils.char_to_utf16_index(LINE, 3).should eq(4)
      Crystalino::PositionUtils.char_to_utf16_index(LINE, 5).should eq(6)
    end
  end
end
