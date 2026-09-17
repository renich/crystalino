require "./support/unwrap"
require "spec"
require "../src/crystalino"

describe Crystalino do
  it "exposes VERSION without starting the server" do
    Crystalino::VERSION.should_not be_nil
    Crystalino::VERSION.should_not be_empty
  end

  it "defines SERVER_CAPABILITIES" do
    Crystalino::SERVER_CAPABILITIES.should_not be_nil
    Crystalino::SERVER_CAPABILITIES.hover_provider.should be_true
    Crystalino::SERVER_CAPABILITIES.definition_provider.should be_true
    Crystalino::SERVER_CAPABILITIES.signature_help_provider.should_not be_nil
  end
end
