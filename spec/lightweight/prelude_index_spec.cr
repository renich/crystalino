require "../support/unwrap"
require "spec"
require "../../src/crystalino/requires"
require "../../src/crystalino/main"
require "../../src/crystalino/lightweight/prelude_index"

describe Crystalino::Lightweight::PreludeIndex do
  it "round-trips the prelude index through the cache format" do
    original = Crystalino::Lightweight::PreludeIndex.generate
    original.should_not be_nil
    original = original.unwrap!
    original.types.size.should be > 500
    original.types["String"]?.should_not be_nil

    path = File.join(Dir.tempdir, "crystalline-prelude-test-#{Random::Secure.hex(8)}.bin")
    begin
      Crystalino::Lightweight::PreludeIndex.save_to_cache_for_test(original, path)
      loaded = Crystalino::Lightweight::PreludeIndex.load_from_cache_for_test(path)
      loaded.should_not be_nil
      loaded = loaded.unwrap!

      loaded.types.size.should eq(original.types.size)
      loaded.top_level_methods.size.should eq(original.top_level_methods.size)

      string_type = loaded.types["String"].should_not be_nil
      string_type.methods.map(&.name).should contain("upcase")
      string_type.methods.map(&.name).should contain("split")
      string_type.parent_types.should contain("Reference")

      # Restrictions and return types survive the round trip.
      to_i = string_type.methods.find(&.name.==("to_i"))
      to_i.should_not be_nil
      to_i.unwrap!.args.first.name.should eq("base")
      to_i.unwrap!.args.first.restriction.should eq("Int")
    ensure
      File.delete(path) if File.exists?(path)
    end
  end

  it "indexes aliases with the aliased type as their parent" do
    index = Crystalino::Lightweight::PreludeIndex.generate
    index.should_not be_nil
    index = index.unwrap!

    mutex = index.types["Mutex"]?
    mutex.should_not be_nil
    mutex.unwrap!.kind.should eq(Crystalino::Lightweight::TypeKind::Alias)
    mutex.unwrap!.parent_types.should contain("Sync::Mutex")
  end
end
