require "lsp/server"
require "../requires"

module Crystalino::Lightweight
  module CompletionKind
    extend self

    def map(kind, *, default = LSP::CompletionItemKind::Variable) : LSP::CompletionItemKind
      case kind
      when Crystal::FileModule
        LSP::CompletionItemKind::File
      when Crystal::Const
        LSP::CompletionItemKind::Constant
      when Crystal::EnumType
        LSP::CompletionItemKind::Enum
      when Crystal::LibType
        LSP::CompletionItemKind::Interface
      when Crystal::AliasType, Crystal::TypeDefType
        LSP::CompletionItemKind::Interface
      when Crystal::PrimitiveType
        LSP::CompletionItemKind::Struct
      when Crystal::ClassType
        kind.struct? ? LSP::CompletionItemKind::Struct : LSP::CompletionItemKind::Class
      when Crystal::ModuleType
        LSP::CompletionItemKind::Module
      else
        default
      end
    end
  end
end
