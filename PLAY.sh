#!/bin/sh
# Launch the game. Uses a release binary when present, otherwise cargo build
# (same as the upstream debug play path). SKATE_ASSETS may be a setup --base
# directory (installation.json) or installations/<id>/assets.
set -e
cd "$(dirname "$0")"

if [ -f "$PWD/.deck-env" ]; then
    # shellcheck disable=SC1091
    . "$PWD/.deck-env"
elif [ -f "$HOME/.cargo/env" ]; then
    # shellcheck disable=SC1091
    . "$HOME/.cargo/env"
fi

resolve_assets() {
    dir=$1
    if [ -f "$dir/private/game.json" ]; then
        printf '%s\n' "$dir"
        return 0
    fi
    if [ -f "$dir/assets/private/game.json" ]; then
        printf '%s\n' "$dir/assets"
        return 0
    fi
    if [ -f "$dir/installation.json" ]; then
        rel=$(sed -n 's/.*"directory"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$dir/installation.json" | head -n 1)
        if [ -n "$rel" ] && [ -f "$dir/$rel/assets/private/game.json" ]; then
            printf '%s\n' "$dir/$rel/assets"
            return 0
        fi
    fi
    return 1
}

resolved=""
if [ -n "${SKATE_ASSETS-}" ]; then
    resolved=$(resolve_assets "$SKATE_ASSETS") || {
        echo "No converted assets under $SKATE_ASSETS" >&2
        echo "Expected private/game.json, or installation.json from tools/setup.py --base." >&2
        exit 1
    }
else
    for candidate in "$HOME/skate3-assets" "$PWD/data" "$PWD/assets"; do
        if resolved=$(resolve_assets "$candidate"); then
            break
        fi
        resolved=""
    done
fi

bin=./target/release/skate3rust
if [ ! -x "$bin" ]; then
    cargo build -p skate-game --bin skate3rust
    bin=./target/debug/skate3rust
fi
[ -x "$bin" ] || { echo "could not find $bin" >&2; exit 1; }

if [ -n "$resolved" ]; then
    echo "PLAY.sh assets=$resolved"
    set -- --assets "$resolved" "$@"
fi
echo "Steam Deck: if only pause works, hold ☰ (Start) 2s to leave desktop keyboard mode."
unset SDL_GAMECONTROLLER_IGNORE_DEVICES
export SDL_JOYSTICK_HIDAPI_STEAMDECK="${SDL_JOYSTICK_HIDAPI_STEAMDECK:-1}"
exec "$bin" "$@"
