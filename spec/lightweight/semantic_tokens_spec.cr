require "../support/unwrap"
require "spec"
require "../../src/crystalline/requires"
require "../../src/crystalline/main"
require "../../src/crystalline/lightweight/semantic_tokens"

describe Crystalline::Lightweight::SemanticTokens do
  it "provides a valid legend with standard token types and modifiers" do
    legend = Crystalline::Lightweight::SemanticTokens.legend
    legend.token_types.should contain("class")
    legend.token_types.should contain("method")
    legend.token_types.should contain("variable")
    legend.token_types.should contain("parameter")
    legend.token_types.should contain("property")
    legend.token_types.should contain("comment")
    legend.token_modifiers.should contain("declaration")
    legend.token_modifiers.should contain("static")
  end

  it "encodes semantic tokens in 5-tuple delta format" do
    source = <<-CRYSTAL
    # A counter
    class Counter
      @count = 0

      def inc(step : Int32)
        @count += step
      end
    end
    CRYSTAL

    tokens = Crystalline::Lightweight::SemanticTokens.tokens(source)
    tokens.should_not be_nil
    tok = tokens.unwrap!
    data = tok.data

    # Data array must be a multiple of 5
    (data.size % 5).should eq(0)
    data.size.should be >= 25

    # Each delta_line and length must be valid
    (0...(data.size // 5)).each do |i|
      delta_line = data[i * 5]
      delta_start = data[i * 5 + 1]
      length = data[i * 5 + 2]
      token_type = data[i * 5 + 3]

      delta_line.should be >= 0
      delta_start.should be >= 0
      length.should be > 0
      token_type.should be >= 0
      token_type.should be < Crystalline::Lightweight::SemanticTokens::TOKEN_TYPES.size
    end
  end

  it "returns nil on empty source" do
    Crystalline::Lightweight::SemanticTokens.tokens("").should be_nil
  end

  it "extracts tokens from broken / incomplete source buffers" do
    source = <<-CRYSTAL
    class Broken
      def foo(
        x = 1
    CRYSTAL

    tokens = Crystalline::Lightweight::SemanticTokens.tokens(source)
    tokens.should_not be_nil
    tok = tokens.unwrap!
    tok.data.should_not be_empty
  end
end
