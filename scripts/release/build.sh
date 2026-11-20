#!/bin/bash
set -eu
cd "$(dirname "$0")/../.."
exec cargo run --locked --manifest-path rust/Cargo.toml --bin package-release -- "$@"
