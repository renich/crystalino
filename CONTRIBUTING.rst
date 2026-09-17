============
Contributing
============

We welcome contributions to ``crystalino``! Please follow these guidelines to make the process smooth for everyone.

Getting Started
===============

#. Fork the repository on GitHub: `<https://github.com/renich/crystalino/fork>`_.
#. Clone your fork locally.
#. Create a new branch for your changes:

   .. code-block:: bash

      git checkout -b feature/my-cool-feature

Environment Setup
=================

Crystalino requires modern Crystal (>= 1.21.0) and system LLVM development libraries to run semantic analysis and build.

On some systems, the compiler may need help locating the ``llvm-config`` binary. You can set the ``LLVM_CONFIG`` environment variable:

.. code-block:: bash

   # MacOS (Homebrew, handles versioned and unversioned LLVM formulae):
   export LLVM_CONFIG="$(brew --prefix $(brew deps --installed crystal 2>/dev/null | grep -E '^llvm(@[0-9]+)?$' || echo llvm))/bin/llvm-config"
   # Or on Fedora/RHEL:
   export LLVM_CONFIG="/usr/bin/llvm-config"

To install development dependencies:

.. code-block:: bash

   shards install

Codebase Architecture
=====================

Crystalino enforces strict domain boundaries:

* **src/crystalino_main.cr**: CLI executable entry point parsing command-line flags.
* **src/crystalino.cr**: Library root providing the public API and embedding entry point.
* **src/crystalino/main.cr**: Server lifecycle bootstrapper and JSON-RPC transport loop.
* **src/crystalino/controller.cr**: JSON-RPC request dispatcher and LSP method routing.
* **src/crystalino/workspace.cr**: LSP workspace orchestrator coordinating document sync, multi-project resolution, and two-tier caching.
* **src/crystalino/analysis/**: Compiler execution on dedicated parallel execution contexts, diagnostics, and AST visitors.
* **src/crystalino/lightweight/**: Sub-millisecond syntax-level symbol indexing, autocompletion, hover, definitions, signature help, folding, selection, and symbols.
* **src/crystalino/formatter/**: Signature and source code formatters.
* **src/crystalino/ext/**: LSP protocol type extensions (semantic tokens, folding ranges).
* **spec/**: Comprehensive test suites (unit, protocol, and integration specs).

Development Workflow
====================

To build the project:

.. code-block:: bash

   shards build crystalino                                       # Debug build
   shards build crystalino --release --no-debug --mcpu=native    # Optimized release build

Formatting & Linting
====================

Always run the formatter, linter, and documentation checker before committing:

.. code-block:: bash

   crystal tool format --check
   ./bin/ameba
   rstcheck CHANGELOG.rst CONTRIBUTING.rst CODE_OF_HONOR.rst

We maintain a strict **zero-suppression policy**: never bypass linter rules with ``# ameba:disable``. Fix the root issue or extract small, single-purpose helper functions.

Debugging & Testing
===================

To run the complete test suite:

.. code-block:: bash

   crystal spec

Since LSP servers communicate over stdin/stdout, standard ``puts`` statements break JSON-RPC framing. Use the built-in LSP logger to print diagnostic information:

.. code-block:: crystal

   LSP::Log.info { "Debugging value: #{my_var}" }

Launch Crystalino with verbose debug logging enabled:

.. code-block:: bash

   ./bin/crystalino -l debug

Commit Guidelines
=================

We strictly follow `Conventional Commits <https://www.conventionalcommits.org/>`_. Format your commit messages with an imperative title, wrapped bodies at 72 characters, and required trailers:

.. code-block:: text

   type(scope): imperative description

   Detailed explanation of rationale and changes wrapped at 72 characters.
   Do not use spaces around forward slashes (e.g. word/word).

   Co-developed-by: Gemini AI <renich+gemini@woralelandia.com>
   Signed-off-by: Rénich Bon Ćirić <renich@woralelandia.com>

* **Types**: ``feat``, ``fix``, ``docs``, ``style``, ``refactor``, ``perf``, ``test``, ``chore``.
* **Mood**: Imperative mood ("add feature", never "added feature").

Submitting a Pull Request
=========================

#. Push your branch to your GitHub fork:

   .. code-block:: bash

      git push origin feature/my-cool-feature

#. Open a Pull Request against the ``master`` branch of `renich/crystalino <https://github.com/renich/crystalino>`_.
#. Provide an empirical description of changes, test coverage, and benchmark impacts.
