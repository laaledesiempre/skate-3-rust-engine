#!/bin/sh
# cargo fetch has no package filter; this pulls the workspace lockfile.
set -e
cd "$(dirname "$0")/.."
cargo fetch --locked
echo "Crate sources are in the local Cargo registry cache."
