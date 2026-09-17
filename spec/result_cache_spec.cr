require "./support/unwrap"
require "spec"
require "../src/crystalino/result_cache"

describe Crystalino::ResultCache do
  it "stores and retrieves results when not invalidated" do
    cache = Crystalino::ResultCache.new
    cache.exists?("foo.cr").should be_false

    cache.set("foo.cr", nil)
    cache.exists?("foo.cr").should be_true
    cache.invalidated?("foo.cr").should be_false
  end

  it "marks entry invalidated upon invalidate" do
    cache = Crystalino::ResultCache.new
    cache.invalidate("foo.cr")
    cache.exists?("foo.cr").should be_true
    cache.invalidated?("foo.cr").should be_true
  end

  it "stores results with unless_invalidated_since when entry was never invalidated" do
    cache = Crystalino::ResultCache.new
    t0 = cache.monotonic_now
    sleep 2.milliseconds

    cache.set("foo.cr", nil, unless_invalidated_since: t0)
    cache.exists?("foo.cr").should be_true
    cache.invalidated?("foo.cr").should be_false
  end

  it "discards result if invalidated after compilation started" do
    cache = Crystalino::ResultCache.new
    t_start = cache.monotonic_now
    sleep 2.milliseconds
    cache.invalidate("foo.cr") # invalidated at t_start + 2ms

    # Try setting result with start time before invalidation
    cache.set("foo.cr", nil, unless_invalidated_since: t_start)
    # Entry should still be invalidated
    cache.invalidated?("foo.cr").should be_true
  end

  it "accepts result if invalidated before compilation started" do
    cache = Crystalino::ResultCache.new
    cache.invalidate("foo.cr")
    sleep 2.milliseconds
    t_start = cache.monotonic_now

    cache.set("foo.cr", nil, unless_invalidated_since: t_start)
    cache.invalidated?("foo.cr").should be_false
  end
end
