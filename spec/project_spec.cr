require "./support/unwrap"
require "spec"
require "file_utils"
require "../src/crystalino/project"

describe Crystalino::Project do
  it "does not match unrelated files once dependencies are known" do
    root = File.join(Dir.tempdir, "crystalino-project-spec-#{Random::Secure.hex(8)}")
    begin
      Dir.mkdir_p(root)
      project = Crystalino::Project.new(URI.parse("file://#{root}"))
      dependency_path = File.join(root, "src", "main.cr")
      unrelated_path = File.join(root, "scratch.cr")
      Dir.mkdir_p(File.dirname(dependency_path))
      File.write(dependency_path, "")
      File.write(unrelated_path, "")

      project.dependencies << dependency_path

      Crystalino::Project.best_fit_for_file([project], URI.parse("file://#{dependency_path}")).should eq(project)
      Crystalino::Project.best_fit_for_file([project], URI.parse("file://#{unrelated_path}")).should be_nil

      # Lightweight queries may opt into a pure path-based fit.
      Crystalino::Project.best_fit_for_file([project], URI.parse("file://#{unrelated_path}"), require_dependency: false).should eq(project)
      Crystalino::Project.best_fit_for_file([project], URI.parse("file://#{dependency_path}"), require_dependency: false).should eq(project)
    ensure
      FileUtils.rm_rf(root)
    end
  end
end
