=========
Changelog
=========

All notable changes to this project will be documented in this file.

The format is based on `Keep a Changelog <https://keepachangelog.com/en/1.1.0/>`_,
and this project adheres to `Semantic Versioning <https://semver.org/spec/v2.0.0.html>`_.

[0.20.0] - 2026-09-17
=====================

Added
-----
* In-Flight Compile Cancellation: Thread-safe ``CancellationToken`` and ``CancellableProgressTracker`` stage interceptor to abort stale background semantic compilation passes immediately upon new document edits, saves, or client cancellations.
* Token & Folding Cache: Versioned document-level caching for Semantic Tokens (0.44ms mean latency) and Folding Ranges (0.15ms mean latency) with automatic cache invalidation on document buffer mutations.
* Domain Modules: Extracted ``Crystalino::DefFormatter``, ``Crystalino::Analysis::AstResolver``, and ``Crystalino::Lightweight::CompletionKind`` into domain-bounded packages.
* Unit Specifications: Unit tests for cancellation tokens, stage interception, and exception propagation (308/308 passing specs).

Changed
-------
* Clean-Break Rebranding: Rebranded project, shard, binary, and namespaces to ``crystalino`` (``module Crystalino``, target executable ``crystalino``).
* Zero Legacy Baggage: Purged all legacy compatibility layers, fallback keys, and deprecated module aliases.
* Modern Concurrency Runtime: Standardized exclusively on native Crystal 1.21+ ``Fiber::ExecutionContext::Parallel`` and purged legacy ``preview_mt``/single-threaded code branches.
* Release Optimization: Native release compilation (``--release --no-debug --mcpu=native``) reducing binary footprint to 15MB (68% reduction) with sub-10ms mean interactive latencies.

Removed
-------
* Obsolete Dependencies: Dropped external ``priority-queue`` shard in favor of standard library sorted collections (``Array#bsearch_index``), and removed unused ``sentry`` target.
* Obsolete Patches: Deleted ``src/crystalline/ext/boehm.cr``, ``src/crystalline/ext/fix_random_warning.cr``, and generic ``src/crystalline/utils.cr``.

[0.19.2] - 2026-09-17
=====================

Added
-----
* LSP Semantic Tokens (``textDocument/semanticTokens/full``): Rich semantic syntax highlighting provider delivering 16 standard token types, 5 token modifiers, relative 5-tuple delta encoding, and robust lexer-based fallback token recovery for broken/unparseable buffers.
* LSP Lexical Rename (``textDocument/prepareRename`` & ``textDocument/rename``): Scope-bounded identifier renaming provider with pre-flight token validation, keyword/comment rejection, prefix-preserving sigil sanitization, and atomic ``WorkspaceEdit`` generation.
* Protocol Tests: JSON-RPC wire-level request deserialization and response serialization specifications for Semantic Tokens, Prepare Rename, and Rename.

Changed
-------
* Documentation Overhaul: Completely rewrote ``README.md`` for Crystalino, highlighting empirical benchmarks (11.7x faster completion, 33.3x faster p95 latency, 68% binary reduction), modernizing editor setups, and establishing MIT attribution.

[0.19.1] - 2026-09-17
=====================

Added
-----
* LSP Workspace Symbols (``workspace/symbol``): Project-wide symbol search powered by the lightweight AST index.
* LSP Signature Help (``textDocument/signatureHelp``): Real-time parameter hints, active parameter detection across commas, and default argument rendering tolerant of partial typing buffers.
* LSP Document Highlight (``textDocument/documentHighlight``): Scoped AST-aware highlight provider distinguishing symbol reads and writes for local variables, instance variables, class variables, methods, types, and constants.
* LSP Folding Range (``textDocument/foldingRange``): Folding region detection for classes, modules, structs, enums, methods, macros, multiline blocks, control flow, multiline strings/heredocs, comments, and import blocks with indentation fallback.
* LSP Selection Range (``textDocument/selectionRange``): Smart expanding hierarchical selection ranges with multi-cursor support.
* JSON-RPC Wire Protocol Test Suite: Comprehensive framing, deserialization, and serialization verification.

Changed
-------
* Modular CLI Architecture: Decoupled CLI argument parser into ``Crystalline::CLI`` with dedicated executable target ``src/crystalline_main.cr``, allowing ``src/crystalline.cr`` to be cleanly imported as a library without blocking STDIN.
* Request Discriminator Registration: Centralized extended LSP RequestMessage JSON discriminator registrations in ``macro finished`` to properly deserialize extended wire methods.
* Static Analysis Hardening: Refactored complex methods and eliminated 100% of Ameba CyclomaticComplexity and ``Lint/NotNil`` violations across the core architecture.

Fixed
-----
* Boehm GC Signal Conflict: Fixed intermittent ``signal 11`` crashes by reverting experimental incremental collection (``mprotect_vdb``) that interfered with Crystal runtime signal handling.
* Wire-Level Request Dropping: Fixed issue where extended requests (``workspace/symbol``, etc.) were parsed as ``UnknownRequest`` due to missing JSON discriminator mappings.

[0.19.0] - 2026-09-16
=====================

Added
-----
* Upstream Sync (v0.19.0): Integrated upstream lightweight analysis engine for instant completion, hover, and go-to-definitions.
* Crystal 1.21 Compatibility: Native Execution Contexts concurrency support and compatibility fixes for Crystal 1.21.
* CLI Option flags: Added ``--log``/``-l`` (to set log severity level) and ``--version``/``-v`` CLI flags.
* CLI Option flags: Added ``--stdio`` flag as a valid no-op to support existing editor plugins (like Emacs/Vim).
* Automatic discovery: Added automatic discovery of ``src/requires.cr`` for finding project entry points.

Changed
-------
* CI & Container: Updated ``Containerfile`` to Crystal 1.21.0-alpine and dropped deprecated ``-Dpreview_mt`` flag.
* Modernized cache: Modernized result cache implementation.
* GC Tuning: Tuned Boehm GC configuration.

Fixed
-----
* Core Stability: Resolved critical deadlocks and infinite loops.
* Sync Drift: Resolved document synchronization drift and improved formatting safety.
* Warnings: Suppressed deprecated ``Random::DEFAULT`` warnings in Crystal standard library.

