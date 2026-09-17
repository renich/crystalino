require "../support/unwrap"
require "spec"
require "../../src/crystalino/requires"
require "../../src/crystalino/main"
require "../../src/crystalino/lightweight/query"
require "../../src/crystalino/lightweight/inference"
require "../../src/crystalino/lightweight/hover"

private def repo_root : String
  File.expand_path("../..", __DIR__)
end

private def prelude_index : Crystalino::Lightweight::Index
  Crystalino::Lightweight::PreludeIndex.ensure_loaded
  until index = Crystalino::Lightweight::PreludeIndex.get
    sleep 50.milliseconds
  end
  index
end

# The pre-compile query shape from Workspace#lightweight_query_for: the
# project's parse-only source index as base, the stdlib prelude underneath,
# and the per-file overlay on top.
private def lightweight_query_for_repo_file(rel : String, source : String) : Crystalino::Lightweight::Query
  path = File.join(repo_root, rel)
  project = Crystalino::Project.new(URI.parse("file://#{repo_root}"))
  overlay = Crystalino::Lightweight::Index.from_source(source, path).unwrap!
  Crystalino::Lightweight::Query.new(project.source_index.unwrap!, secondary: prelude_index, overlay: overlay)
end

Crystalino::EnvironmentConfig.run

describe Crystalino::Lightweight do
  # The untyped-arg seed scan is cursor-independent and memoized per def on
  # the query (commit 3fd5c44): repeated requests on the same buffer must
  # return IDENTICAL types, for both a directly-typed arg and the
  # caller-walk (`token`) family.
  describe "untyped-arg seed cache" do
    it "returns identical types for cold and cached requests" do
      source = File.read(File.join(repo_root, "src/crystalino/lightweight/inference.cr"))
      query = lightweight_query_for_repo_file("src/crystalino/lightweight/inference.cr", source)
      li = source.lines.index(&.includes?("node.expressions.each")) || raise "seed site line not found"

      types = [] of Array(String)
      3.times do
        inference = Crystalino::Lightweight::Inference.for(source, li + 1, 10, query)
        types << inference.unwrap!.types_for("node").sort
      end

      types[0].should eq(["Crystal::Expressions"])
      types[1].should eq(types[0])
      types[2].should eq(types[0])
    end

    it "keeps the caller-walk token family resolving through the cache" do
      source = File.read(File.join(repo_root, "src/crystalino/completion_context.cr"))
      query = lightweight_query_for_repo_file("src/crystalino/completion_context.cr", source)
      li = source.lines.index(&.includes?("case token.type")) || raise "token site line not found"
      col = source.lines[li].index!("type")

      hov, why = Crystalino::Lightweight::Hover.hover_and_reason(source, li, col, query)
      hov.should_not be_nil, why
      hov2, _ = Crystalino::Lightweight::Hover.hover_and_reason(source, li, col, query)
      hov2.should_not be_nil

      inference = Crystalino::Lightweight::Inference.for(source, li + 1, col + 1, query)
      inference.unwrap!.types_for("token").should contain("Crystal::Token")
    end
  end
end
