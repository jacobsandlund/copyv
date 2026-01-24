# copyv

Version control for copy paste!

## Project Overview

`src/main.zig` contains all the code for this small executable. It finds all `copyv:` tags and updates the copied code from changes made to the source, even allowing merges.

## Build & Commands

* Build and run with: `zig build run`

Right now, use `zig build run` and check the diff of changes in `examples` (except for minor changes like adding new `file_type_info_map` entries).

## Code

Prefer self-documenting code to comments, but add detailed comments for anything that needs explanation.

Never leave trailing whitespace in lines of source code.

This is Zig 0.15, so use std.Io, format strings with "{s}".
