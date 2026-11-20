#!/bin/bash
set -eu
cd "$(dirname "$0")/.."
cargo test --locked --manifest-path rust/Cargo.toml "$@"
mkdir -p .build
exec cargo run --locked --manifest-path rust/Cargo.toml --bin panel -- --render-fixture "$PWD/.build/rust-panel.png"
