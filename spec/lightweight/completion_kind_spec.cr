require "../support/unwrap"
require "spec"
require "../../src/crystalino/requires"
require "../../src/crystalino/lightweight/completion_kind"

describe Crystalino::Lightweight::CompletionKind do
  it "maps Crystal type representations to LSP CompletionItemKind" do
    program = Crystal::Program.new

    program.types["Int32"]?.try do |int_type|
      Crystalino::Lightweight::CompletionKind.map(int_type).should eq(LSP::CompletionItemKind::Struct)
    end

    Crystalino::Lightweight::CompletionKind.map(program).should eq(LSP::CompletionItemKind::Module)
    Crystalino::Lightweight::CompletionKind.map("unknown_object").should eq(LSP::CompletionItemKind::Variable)
    Crystalino::Lightweight::CompletionKind.map("custom_default", default: LSP::CompletionItemKind::Constant).should eq(LSP::CompletionItemKind::Constant)
  end
end
