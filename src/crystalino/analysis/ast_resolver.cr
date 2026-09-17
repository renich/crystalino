require "lsp/server"
require "compiler/crystal/syntax"

module Crystalino::Analysis
  module AstResolver
    extend self

    def locations_from_path(path : Crystal::Path, nodes : Array(Crystal::ASTNode)) : Array({Crystal::Location, Crystal::Location})?
      target = resolve_path(path, nodes)
      target.as?(Crystal::Const | Crystal::Type).try &.locations.try &.map do |location|
        end_location = Crystal::Location.new(
          location.filename,
          line_number: location.line_number + 1,
          column_number: 0
        )
        {location, end_location}
      end
    end

    def locations_from_union(
      union : Crystal::Union,
      nodes : Array(Crystal::ASTNode),
      *,
      locations = [] of {Crystal::Location, Crystal::Location},
    ) : Array({Crystal::Location, Crystal::Location})
      union.types.each do |type|
        if type.is_a?(Crystal::Path)
          locations_from_path(type, nodes).try do |locs|
            locations.concat(locs)
          end
        elsif type.is_a?(Crystal::Union)
          locations_from_union(type, nodes, locations: locations)
        elsif location = type.location
          end_location = type.end_location || location
          locations << {location, end_location}
        end
      end
      locations
    end

    def resolve_path(path : Crystal::Path, ast_nodes : Array(Crystal::ASTNode))
      resolved_path = path.type? || path.target_const || path.target_type || ast_nodes[..-2]?.try &.reverse_each.reduce(nil) do |_, elt|
        typ = elt.responds_to?(:resolved_type) ? elt.resolved_type : nil
        typ ||= elt.type?

        if found_path = typ.try(&.lookup_path(path))
          break found_path
        end
      end

      if resolved_path.is_a?(Crystal::Type)
        resolved_path.instance_type
      else
        resolved_path
      end
    end

    def lsp_range_from_node(node : Crystal::ASTNode) : LSP::Range
      start_location = node.location
      end_location = node.end_location || start_location
      LSP::Range.new(
        start: LSP::Position.new(
          line: start_location.try(&.line_number.- 1) || 0,
          character: start_location.try(&.column_number.- 1) || 0,
        ),
        end: LSP::Position.new(
          line: end_location.try(&.line_number.- 1) || 0,
          character: end_location.try(&.column_number.- 1) || 0,
        ),
      )
    end
  end
end
