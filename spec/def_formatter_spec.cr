require "./support/unwrap"
require "spec"
require "compiler/crystal/syntax"
require "../src/crystalino/formatter/def_formatter"

describe Crystalino::DefFormatter do
  it "formats a method with arguments and return type without extra spaces" do
    parser = Crystal::Parser.new("def greet(name : String) : String\n  name\nend")
    node = parser.parse.as(Crystal::Def)

    formatted = Crystalino::DefFormatter.format_def(node, short: true)
    formatted.should eq("greet(name : String) : String")
  end

  it "formats a method without arguments cleanly" do
    parser = Crystal::Parser.new("def calculate : Int32\n  42\nend")
    node = parser.parse.as(Crystal::Def)

    formatted = Crystalino::DefFormatter.format_def(node, short: true)
    formatted.should eq("calculate : Int32")
  end

  it "formats block arguments with names and types" do
    parser = Crystal::Parser.new("def map(&block : T -> U)\nend")
    node = parser.parse.as(Crystal::Def)

    formatted = Crystalino::DefFormatter.format_def(node, short: true)
    formatted.should eq("map(&block : (T -> U))")
  end
end
