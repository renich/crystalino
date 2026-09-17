# Reopens LSP::CodeActionKind to handle open sets of code action kinds.
# According to LSP 3.17 section 3.17.0:
# "The CodeActionKind type is defined as string. The set of kinds is open;
# clients and servers are free to invent sub-kinds."
#
# Clients such as Vim (yegappan/lsp) announce "source.fixAll", which would
# otherwise trigger an ArgumentError during JSON deserialization of ClientCapabilities.
enum LSP::CodeActionKind
  def self.parse(string : String) : self
    case string
    when ""                       then Empty
    when "quickfix"               then QuickFix
    when "refactor"               then Refactor
    when "refactor.extract"       then RefactorExtract
    when "refactor.inline"        then RefactorInline
    when "refactor.rewrite"       then RefactorRewrite
    when "source"                 then Source
    when "source.organizeImports" then SourceOrganizeImports
    when "source.fixAll"          then Source
    else
      # Fallback for open kinds defined by client implementations
      Empty
    end
  end
end
