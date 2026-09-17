require "./support/unwrap"
require "spec"
require "../src/crystalino"

describe Crystalino::CancellationToken do
  it "initializes in uncancelled state" do
    token = Crystalino::CancellationToken.new
    token.cancelled?.should be_false
  end

  it "transitions to cancelled state upon cancel" do
    token = Crystalino::CancellationToken.new
    token.cancel
    token.cancelled?.should be_true
  end
end

describe Crystalino::CompilationCancelledException do
  it "records the cancellation stage name" do
    ex = Crystalino::CompilationCancelledException.new("Semantic (main)")
    ex.stage.should eq("Semantic (main)")
    ex.message.unwrap!.should contain("Semantic (main)")
  end
end

describe Crystalino::Analysis::CancellableProgressTracker do
  it "executes stages normally when uncancelled" do
    token = Crystalino::CancellationToken.new
    tracker = Crystalino::Analysis::CancellableProgressTracker.new(token)
    executed = false

    result = tracker.stage("TestStage") do
      executed = true
      42
    end

    executed.should be_true
    result.should eq(42)
  end

  it "raises CompilationCancelledException before stage when pre-cancelled" do
    token = Crystalino::CancellationToken.new
    token.cancel
    tracker = Crystalino::Analysis::CancellableProgressTracker.new(token)

    expect_raises(Crystalino::CompilationCancelledException) do
      tracker.stage("PreCancelledStage") do
        "should not execute"
      end
    end
  end

  it "raises CompilationCancelledException after stage when cancelled mid-stage" do
    token = Crystalino::CancellationToken.new
    tracker = Crystalino::Analysis::CancellableProgressTracker.new(token)

    expect_raises(Crystalino::CompilationCancelledException) do
      tracker.stage("MidCancelledStage") do
        token.cancel
        "cancelled during execution"
      end
    end
  end
end
