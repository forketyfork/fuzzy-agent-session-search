default:
    @just --list

build:
    zig build

test:
    zig build test

run *ARGS:
    zig build run -- {{ARGS}}

run-release *ARGS:
    zig build run -Doptimize=ReleaseFast -- {{ARGS}}

fmt:
    zig fmt src test build.zig build.zig.zon

fmt-check:
    zig fmt --check src test build.zig build.zig.zon

lint:
    zig fmt --check src test build.zig build.zig.zon
    zig build lint

ci: build test lint
