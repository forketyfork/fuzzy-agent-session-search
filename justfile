default:
    @just --list

build:
    zig build

test:
    zig build test

run *ARGS:
    zig build run -- {{ARGS}}

fmt:
    zig fmt src build.zig

fmt-check:
    zig fmt --check src build.zig

lint:
    zig fmt --check src build.zig
    zig build lint

ci: build test lint
