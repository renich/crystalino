require "lsp/server"
require "compiler/crystal/syntax"

module Crystalino::Lightweight
  module CompletionKind
    extend self

    def map(kind, *, default = LSP::CompletionItemKind::Variable) : LSP::CompletionItemKind
      case kind
      when Crystal::FileModule
        LSP::CompletionItemKind::File
      when Crystal::Const
        LSP::CompletionItemKind::Constant
      when Crystal::ClassType
        LSP::CompletionItemKind::Class
      when Crystal::EnumType
        LSP::CompletionItemKind::Enum
      when Crystal::LibType
        LSP::CompletionItemKind::Interface
      when Crystal::ModuleType
        LSP::CompletionItemKind::Module
      else
        default
      end
    end
  end
end
