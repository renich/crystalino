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

  it "propagates cancellation concurrently across multiple fibers" do
    token = Crystalino::CancellationToken.new
    reader_count = 10
    observed_channel = Channel(Bool).new

    reader_count.times do
      spawn do
        cancelled = false
        100.times do
          if token.cancelled?
            cancelled = true
            break
          end
          Fiber.yield
        end
        observed_channel.send(cancelled)
      end
    end

    Fiber.yield
    token.cancel

    results = [] of Bool
    reader_count.times do
      results << observed_channel.receive
    end

    results.all?(&.itself).should be_true
    token.cancelled?.should be_true
  end

  it "handles concurrent multi-fiber cancellation safely" do
    token = Crystalino::CancellationToken.new
    fiber_count = 8
    done = Channel(Nil).new

    fiber_count.times do
      spawn do
        token.cancel
        done.send(nil)
      end
    end

    fiber_count.times { done.receive }
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
