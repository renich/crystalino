require "./support/unwrap"
require "spec"
require "../src/crystalline"

describe Crystalline do
  it "exposes VERSION without starting the server" do
    Crystalline::VERSION.should_not be_nil
    Crystalline::VERSION.should_not be_empty
  end

  it "defines SERVER_CAPABILITIES" do
    Crystalline::SERVER_CAPABILITIES.should_not be_nil
    Crystalline::SERVER_CAPABILITIES.hover_provider.should be_true
    Crystalline::SERVER_CAPABILITIES.definition_provider.should be_true
    Crystalline::SERVER_CAPABILITIES.signature_help_provider.should_not be_nil
  end
end
