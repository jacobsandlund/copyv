# copyv

Version control for copy paste!

## Project Overview

`src/main.zig` contains all the code for this small executable. It finds all `copyv:` tags and updates the copied code from changes made to the source, even allowing merges.

A **slice** is the unit this tool operates on: the region of a file between a `copyv:` begin tag and its matching `end` tag, mirroring a region of the source file (or the whole source file, when the URL has no line numbers). A slice is a region of text, not a syntactic unit — it may hold part of a code block, exactly one, or many. Use "slice" for this concept throughout the code and docs; never "block" or "chunk". Where the Zig sense of a slice (`[]const u8`) needs a name, call it `bytes` or `text`.

## Build & Commands

* Build and run with: `zig build run -- .` (`copyv` with no paths prints usage)

Right now, use `zig build run -- .` and check the diff of changes in `examples` (except for minor changes like adding new `file_type_info_map` entries).

## Code

Prefer self-documenting code to comments, but add detailed comments for anything that needs explanation.

Never leave trailing whitespace in lines of source code.

