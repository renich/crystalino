require "compiler/crystal/syntax"

module Crystalino
  module DefFormatter
    extend self

    # Format a method definition or macro into human-readable signature.
    def format_def(d : Crystal::Def | Crystal::Macro, *, short = false) : String
      String.build do |str|
        unless short
          str << d.visibility.to_s.downcase
          str << ' '
        end

        str << d.name

        if d.args.size > 0 || d.block_arg || d.double_splat
          format_def_args(str, d)
        end
        if d.responds_to?(:return_type) && (return_type = d.return_type)
          str << " : #{return_type}"
        end

        if d.responds_to?(:free_vars) && (free_vars = d.free_vars)
          str << " forall "
          free_vars.join(str, ", ")
        end
      end
    rescue
      d.to_s
    end

    private def format_def_args(str : String::Builder, d : Crystal::Def | Crystal::Macro)
      str << '('
      printed_arg = false
      d.args.each_with_index do |arg, idx|
        str << ", " if printed_arg
        str << '*' if d.splat_index == idx
        str << arg.to_s
        printed_arg = true
      end
      if double_splat = d.double_splat
        str << ", " if printed_arg
        str << "**"
        str << double_splat
        printed_arg = true
      end
      if block_arg = d.block_arg
        str << ", " if printed_arg
        str << '&'
        str << block_arg
        printed_arg = true
      end
      str << ')'
    end
  end
end
