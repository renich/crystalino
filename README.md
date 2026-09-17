<div align="center">
  <img src="assets/icon.svg" width="128" height="128" alt="Crystalino Logo" />
  <h1>Crystalino</h1>
  <p><strong>The High-Performance, Next-Generation Language Server for Crystal</strong></p>

  <a href="https://github.com/renich/crystalino/actions?query=branch%3Amaster+workflow%3ABuild"><img alt="Build Status" src="https://github.com/renich/crystalino/workflows/Build/badge.svg?branch=master"></a>
  <a href="https://github.com/renich/crystalino/tags"><img alt="GitHub tag (latest SemVer)" src="https://img.shields.io/github/v/tag/renich/crystalino"></a>
  <a href="LICENSE"><img alt="License: MIT" src="https://img.shields.io/badge/License-MIT-blue.svg"></a>
  <a href="https://crystal-lang.org"><img alt="Crystal: >= 1.21" src="https://img.shields.io/badge/Crystal-%3E%3D%201.21-black.svg"></a>
</div>

<hr/>

**Crystalino** is a re-engineered, high-performance implementation of the [Language Server Protocol (LSP)](https://microsoft.github.io/language-server-protocol/) written in and for the [Crystal Language](https://crystal-lang.org/). Forked from the original `crystalline` project, Crystalino delivers instantaneous response times, rock-solid Boehm GC stability, zero-nil safety, and expanded modern LSP capabilities.

---

## Empirical Performance

Benchmarked against a 1,100-line real-world Crystal source file ([`src/crystalino/workspace.cr`](src/crystalino/workspace.cr)) on Crystal 1.21:

| Metric | Upstream (`v0.19.0`) | Crystalino (`v0.19.2` Release Native) | Improvement |
| :--- | :--- | :--- | :--- |
| **Completion Mean Latency** | `75.01 ms` | **`6.40 ms`** | **11.7x faster** |
| **Completion p95 Tail Latency** | `281.98 ms` | **`8.46 ms`** | **33.3x faster** |
| **Hover Mean Latency** | `24.33 ms` | **`5.43 ms`** | **4.5x faster** |
| **Hover p95 Latency** | `71.05 ms` | **`11.60 ms`** | **6.1x faster** |
| **Definition Mean Latency** | `58.21 ms` | **`6.18 ms`** | **9.4x faster** |
| **Definition p95 Latency** | `32.18 ms` | **`7.61 ms`** | **4.2x faster** |
| **`didOpen` (1,060 LOC)** | `1.32 ms` | **`1.10 ms`** | **17% faster** |
| **Peak Memory Footprint (HWM)** | `434,148 KB` | **`320,072 KB`** | **114 MB/26% lower** |
| **Binary Executable Size** | `46 MB` | **`15 MB`** | **68% smaller** |
| **Shutdown Lifecycle** | `Signal(TERM)` (Hung) | **`Exit 0`** | **Deterministic exit** |

### Why Crystalino is Faster & More Reliable

1. **Sub-10ms Tail Latencies**: In release mode with whole-program optimization and host vectorization (`--release --no-debug --mcpu=native`), autocompletion p95 latency stays strictly under **9 ms** with zero typing stutter.
2. **Boehm GC Stability**: Upstream's experimental incremental collection (`mprotect_vdb`) clashing with Crystal 1.21's signal handlers has been replaced with stable memory tuning, completely eliminating intermittent `Signal 11` crashes and saving **114 MB** of peak RAM.
3. **Hardened Code Quality**: 0 Ameba violations across all files, cyclomatic complexity $\le 10$ across all methods, and zero unsafe `.not_nil!` assertions.

---

## Features

Crystalino implements comprehensive Language Server Protocol capabilities:

- **Autocompletion (`textDocument/completion`)**: Context-aware identifier, method, type, macro, and symbol suggestions ranked closest-type-first.
- **Signature Help (`textDocument/signatureHelp`)**: Real-time parameter hints, docstrings, active argument tracking across commas, and default argument rendering tolerant of partial typing buffers.
- **Semantic Tokens (`textDocument/semanticTokens/full`)**: Rich 16-type syntax highlighting with relative 5-tuple delta encoding and automated lexer fallback recovery for unparseable editing buffers.
- **Lexical Rename (`textDocument/prepareRename` & `textDocument/rename`)**: Scope-bounded identifier renaming with sigil sanitization (`@`/`@@`) and atomic `WorkspaceEdit` generation.
- **Document Highlight (`textDocument/documentHighlight`)**: Scoped AST-aware read/write symbol occurrences.
- **Folding Range (`textDocument/foldingRange`)**: Region folding for classes, modules, structs, defs, macros, blocks, control flow, multiline heredocs, and comments.
- **Selection Range (`textDocument/selectionRange`)**: Smart hierarchical AST expanding selection with multi-cursor support.
- **Go-to Definition (`textDocument/definition`)**: Instant symbol navigation via lightweight index and fallback compiler analysis.
- **Hover Documentation (`textDocument/hover`)**: Type signatures, docstrings, and expanded macros.
- **Document Symbols (`textDocument/documentSymbol`)**: Full hierarchical symbol outline for editors and breadcrumbs.
- **Workspace Symbols (`workspace/symbol`)**: Project-wide fuzzy symbol lookup.
- **Formatting (`textDocument/formatting` & `rangeFormatting`)**: Format source code cleanly via `crystal tool format`.
- **Diagnostics (`textDocument/publishDiagnostics`)**: Real-time syntax and semantic errors on save and typing.

---

## Installation

### Pre-Built Binaries

Pre-compiled, statically linked binaries are available on the [Releases Page](https://github.com/renich/crystalino/releases):

```bash
# Download and extract the latest Linux x86_64 binary
wget https://github.com/renich/crystalino/releases/latest/download/crystalino_x86_64-unknown-linux-musl.gz -O crystalino.gz
gzip -d crystalino.gz
chmod u+x crystalino
sudo mv crystalino /usr/local/bin/crystalino
```

### Build from Source

Requirements: Crystal $\ge 1.21.0$ and system `llvm-config`.

```bash
git clone https://github.com/renich/crystalino.git
cd crystalino
shards install

# Compile high-performance optimized release binary
shards build crystalino --release --no-debug --mcpu=native

# Install to PATH
sudo cp ./bin/crystalino /usr/local/bin/crystalino
```

---

## Editor & Agent Configuration

### Vim 9 (`yegappan/lsp`)

Using Vim 9's native Vim9script LSP client ([`yegappan/lsp`](https://github.com/yegappan/lsp)):

1. Install the plugin into your Vim package path:

```bash
git clone https://github.com/yegappan/lsp.git ~/.vim/pack/local/start/lsp
vim -u NONE -c "helptags ~/.vim/pack/local/start/lsp/doc" -c "q"
```

2. Add the following to your `~/.vimrc`:

```vim
" Disable legacy vim-crystal compiler runners to prevent blocking
let g:crystal_define_mappings = 0
let g:crystal_enable_completion = 0
let g:ale_linters = {'crystal': []}

if executable('crystalino')
    " Configure LSP display options
    let g:lsp_options = #{
        \ autoHighlightDiags: v:true,
        \ showDiagInPopup: v:true,
        \ diagVirtualText: v:true,
        \ autoComplete: v:true,
        \ }

    " Register Crystalino language server
    let g:lsp_servers = [#{
        \ name: 'crystalino',
        \ filetype: ['crystal'],
        \ path: 'crystalino',
        \ args: ['--stdio'],
        \ rootSearch: ['shard.yml', '.git/'],
        \ syncInit: v:true,
        \ }]

    " Buffer mappings for Crystal files
    augroup CrystalinoMappings
        autocmd!
        autocmd FileType crystal nnoremap <buffer> <silent> gd <cmd>LspGotoDefinition<cr>
        autocmd FileType crystal nnoremap <buffer> <silent> K  <cmd>LspHover<cr>
        autocmd FileType crystal nnoremap <buffer> <silent> [d <cmd>LspDiag prev<cr>
        autocmd FileType crystal nnoremap <buffer> <silent> ]d <cmd>LspDiag next<cr>
        autocmd FileType crystal nnoremap <buffer> <silent> <leader>rn <cmd>LspRename<cr>
        autocmd FileType crystal nnoremap <buffer> <silent> <leader>f  <cmd>LspFormat<cr>
    augroup END
endif
```

### Neovim

#### Native LSP (Neovim 0.11/0.12+)

In `~/.config/nvim/init.lua`:

```lua
-- Register Crystalino language server
if vim.fn.executable("crystalino") == 1 then
    vim.lsp.config["crystalino"] = {
        cmd = { "crystalino", "--stdio" },
        filetypes = { "crystal" },
        root_markers = { "shard.yml", ".git" },
    }
    vim.lsp.enable("crystalino")
end

-- Keybindings and buffer configuration
vim.api.nvim_create_autocmd("LspAttach", {
    desc = "LSP keybindings and buffer options",
    callback = function(args)
        local bufnr = args.buf
        local map = function(mode, lhs, rhs, desc)
            vim.keymap.set(mode, lhs, rhs, { buffer = bufnr, silent = true, desc = desc })
        end

        map("n", "gd", vim.lsp.buf.definition, "LSP: Go to Definition")
        map("n", "K", vim.lsp.buf.hover, "LSP: Hover Documentation")
        map("n", "<leader>rn", vim.lsp.buf.rename, "LSP: Rename Symbol")
        map("n", "<leader>f", function() vim.lsp.buf.format({ async = true }) end, "LSP: Format Buffer")
        map("n", "[d", vim.diagnostic.goto_prev, "LSP: Previous Diagnostic")
        map("n", "]d", vim.diagnostic.goto_next, "LSP: Next Diagnostic")
    end,
})
```

#### With `nvim-lspconfig` (Neovim legacy $\le$ 0.10)

```lua
local lspconfig = require('lspconfig')

lspconfig.crystalline.setup({
  cmd = { "crystalino", "--stdio" },
  filetypes = { "crystal" },
  root_dir = lspconfig.util.root_pattern("shard.yml", ".git"),
})
```

### Crush/Antigravity Agent Terminal (`crush.json`)

In `~/.config/crush/crush.json`:

```json
{
  "lsp": {
    "crystal": {
      "command": "crystalino",
      "args": ["--stdio"]
    }
  }
}
```

### VSCode

Install the [Crystal Language extension](https://marketplace.visualstudio.com/items?itemName=crystal-lang-tools.crystal-lang). In `settings.json`:

```json
{
  "crystal-lang.server": "/usr/local/bin/crystalino"
}
```

### Helix

In `~/.config/helix/languages.toml`:

```toml
[language-server.crystalino]
command = "crystalino"
args = ["--stdio"]

[[language]]
name = "crystal"
language-servers = ["crystalino"]
```

### Zed

In `~/.config/zed/settings.json`:

```json
{
  "languages": {
    "Crystal": {
      "language_servers": ["crystalino"]
    }
  },
  "lsp": {
    "crystalino": {
      "binary": {
        "path": "crystalino",
        "arguments": ["--stdio"]
      }
    }
  }
}
```

### Emacs (`lsp-mode`)

```elisp
(with-eval-after-load 'lsp-mode
  (add-to-list 'lsp-language-id-configuration '(crystal-mode . "crystal"))
  (lsp-register-client
    (make-lsp-client :new-connection (lsp-stdio-connection '("crystalino" "--stdio"))
                     :activation-fn (lsp-activate-on "crystal")
                     :priority 1
                     :server-id 'crystalino)))
```

---

## AI Agents & Antigravity (AGY) Integration

### The Crystal Tooling Duo: Crystalino LSP + Crystal MCP Server

For autonomous AI coding agents (such as Google Antigravity, Claude Code, OpenCode, and Cursor), Crystalino pairs seamlessly with the **[Crystal MCP Server](https://gitlab.com/renich/crystal-mcp)** (`renich/crystal-mcp`):

- **[Crystalino](https://github.com/renich/crystalino)** provides **LSP Intelligence**: real-time document parsing, diagnostics, hover tooltips, go-to-definition, parameter signature hints, semantic highlighting, and lexical renaming.
- **[Crystal MCP Server](https://gitlab.com/renich/crystal-mcp)** provides **Agentic Tool Execution**: zero-codegen build checks (`check_build`), targeted spec runs with line-level filtering (`run_spec`), code formatting (`format_code`), static code analysis via Ameba (`lint_code`), macro expansions (`expand_macro`), and structured type hierarchy JSON (`get_hierarchy`).

#### Configuring `crystal-mcp` for Antigravity (AGY)

In your global or workspace Antigravity MCP configuration (`~/.gemini/config/mcp_config.json`):

```json
{
  "mcpServers": {
    "crystal-mcp": {
      "command": "/home/YOUR_USER/.local/bin/crystal-mcp",
      "args": [],
      "env": {}
    }
  }
}
```

---

## Workspace Configuration (`shard.yml`)

Crystalino automatically discovers project entry points (`targets`, `src/main.cr`, `src/requires.cr`). You can customize behavior in your project's `shard.yml`:

```yaml
# Override entry point for libraries/specs
crystalino:
  main: spec/spec_helper.cr

# Support monorepos/multi-project workspaces
crystalino:
  projects:
    - services/auth
    - services/api
```

---

## Development & Testing

```bash
# Run unit & protocol test suites (332 examples)
crystal spec

# Run static code analysis (0 violations required)
./bin/ameba

# Check code formatting
crystal tool format --check
```

---

## License & Attribution

Crystalino is released under the **MIT License**. See [LICENSE](LICENSE) for details.

This project is a continuation and modernization of **`crystalline`**, originally created and licensed under the MIT License by [Julien Elbaz](https://github.com/elbywan) and contributors. We gratefully acknowledge their foundational work in establishing the Language Server Protocol for Crystal.
