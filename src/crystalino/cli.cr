require "option_parser"
require "log"

module Crystalino
  module CLI
    def self.run(args = ARGV)
      log_level = ::Log::Severity::Warn

      OptionParser.parse(args) do |parser|
        parser.banner = "Usage: crystalino [options]"

        parser.on("-v", "--version", "Show version") do
          puts Crystalino::VERSION
          exit
        end

        parser.on("-h", "--help", "Show help") do
          puts parser
          exit
        end

        parser.on("-l LEVEL", "--log LEVEL", "Set log level (debug, info, warn, error). Default: warn") do |level|
          log_level = parse_log_level(level)
        end

        parser.on("--stdio", "Use standard I/O (default)") do
          # No-op: standard I/O is the only transport supported by crystalino
        end

        parser.invalid_option do |flag|
          STDERR.puts "ERROR: #{flag} is not a valid option."
          STDERR.puts parser
          exit 1
        end
      end

      Crystalino.init(log_level: log_level)
    end

    private def self.parse_log_level(level : String) : ::Log::Severity
      case level.downcase
      when "debug" then ::Log::Severity::Debug
      when "info"  then ::Log::Severity::Info
      when "warn"  then ::Log::Severity::Warn
      when "error" then ::Log::Severity::Error
      else
        STDERR.puts "Invalid log level: #{level}"
        exit 1
      end
    end
  end
end
