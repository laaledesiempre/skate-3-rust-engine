#!/bin/sh
# Steam Deck / Linux entry point. Full guided install is steamdeck_setup.sh.
# --toolchain-only keeps the old rustup / micromamba / cargo fetch behaviour.
set -e
cd "$(dirname "$0")"
exec ./steamdeck_setup.sh "$@"
