#!/bin/sh
# Steam Deck: clone (if needed), home-folder toolchain, ./BUILD.sh, Xbox 360
# ISO extract, asset convert. No sudo. Same Cargo features as other Linux
# glibc builds (Steam + UDP stay on).
#
# Deck hurdles: cargo fetch has no -p; cc/pkg-config live in $HOME/ccenv;
# conda-forge package is libudev (not eudev); skate-xiso is a workspace crate;
# PLAY.sh accepts the setup --base dir; Xbox 360 default.xex only (not PS3).
#
#   ./steamdeck_setup.sh
#   ./steamdeck_setup.sh --source /path/to/skate3-360.iso
set -e

repo_url="${SKATE_DECK_REPO:-https://github.com/dhcerebro/skate-3-rust-engine-linux.git}"
clone_dest="${SKATE_DECK_ROOT:-$HOME/skate-3-rust-engine-linux}"
prefix="${SKATE_DECK_PREFIX:-$HOME/ccenv}"
assets_base="${SKATE_ASSETS_BASE:-$HOME/skate3-assets}"
extract_dir="${SKATE_XEX_DIR:-$HOME/skate3-xex}"
source_path="${SKATE_SOURCE-}"
toolchain_only=0
rebuild=0
reconvert=0

die() { echo "steamdeck_setup.sh: $*" >&2; exit 1; }

bootstrap_repo() {
    echo "=== 0/7 clone $repo_url ==="
    command -v git >/dev/null 2>&1 || die "git not found"
    if [ -f "$clone_dest/Cargo.toml" ] && [ -f "$clone_dest/steamdeck_setup.sh" ]; then
        echo "already cloned: $clone_dest"
    else
        if [ -e "$clone_dest" ] && [ ! -d "$clone_dest/.git" ]; then
            die "$clone_dest exists and is not this repo"
        fi
        if [ -n "${SKATE_DECK_BRANCH-}" ]; then
            git clone --branch "$SKATE_DECK_BRANCH" --single-branch "$repo_url" "$clone_dest"
        else
            git clone "$repo_url" "$clone_dest"
        fi
    fi
    script="$clone_dest/steamdeck_setup.sh"
    [ -f "$script" ] || die "clone is missing steamdeck_setup.sh"
    chmod +x "$script" 2>/dev/null || true
    echo "re-exec $script"
    if [ -r /dev/tty ]; then
        exec "$script" "$@" < /dev/tty
    fi
    exec "$script" "$@"
}

here=$(CDPATH= cd -- "$(dirname -- "$0")" 2>/dev/null && pwd) || here=""
if [ ! -f "${here}/Cargo.toml" ] || [ ! -f "${here}/crates/skate-xiso/Cargo.toml" ]; then
    bootstrap_repo "$@"
fi
cd "$here"
root=$PWD
envfile=$root/.deck-env

usage() {
    cat <<'EOF'
Usage: ./steamdeck_setup.sh [options]

  --source PATH     Xbox 360 Skate 3 .iso or extracted default.xex
  --toolchain-only  rustup + micromamba + cargo fetch only
  --rebuild         Rebuild skate3rust / skate-xiso even if they exist
  --reconvert       Run asset conversion even if installation.json exists
  --help            This text

Env: SKATE_DECK_REPO, SKATE_DECK_BRANCH, SKATE_DECK_ROOT, SKATE_DECK_PREFIX,
     SKATE_ASSETS_BASE, SKATE_XEX_DIR, SKATE_SOURCE
EOF
}

while [ $# -gt 0 ]; do
    case $1 in
        --source) source_path=$2; shift 2 ;;
        --source=*) source_path=${1#--source=}; shift ;;
        --toolchain-only) toolchain_only=1; shift ;;
        --rebuild) rebuild=1; shift ;;
        --reconvert) reconvert=1; shift ;;
        --help|-h) usage; exit 0 ;;
        *) die "unknown option: $1 (try --help)" ;;
    esac
done

expand_path() {
    p=$1
    case $p in
        ~) p=$HOME ;;
        ~/*) p=$HOME/${p#~/} ;;
    esac
    printf '%s\n' "$p"
}

ask() {
    var=$1
    shift
    [ -t 0 ] || die "not a terminal; pass --source /path/to/iso-or-default.xex"
    printf '%s' "$*"
    read -r "$var" || die "no input"
}

install_toolchain() {
    echo "=== 1/7 rustup (1.85+ / edition 2024) ==="
    if ! command -v rustup >/dev/null 2>&1; then
        if [ ! -x "$HOME/.cargo/bin/rustup" ]; then
            curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --default-toolchain stable
        fi
    fi
    # shellcheck disable=SC1091
    [ -f "$HOME/.cargo/env" ] && . "$HOME/.cargo/env"
    command -v rustc >/dev/null 2>&1 || die "rustc not on PATH after rustup"
    rustup toolchain install stable
    rustup default stable
    echo "rustc $(rustc --version)"

    echo "=== 2/7 micromamba toolchain in $prefix (no sudo) ==="
    micromamba=""
    for candidate in \
        "${MAMBA_EXE-}" \
        "$HOME/bin/micromamba" \
        "$HOME/micromamba" \
        "$prefix/bin/micromamba" \
        "$(command -v micromamba 2>/dev/null || true)"
    do
        if [ -n "$candidate" ] && [ -x "$candidate" ]; then
            micromamba=$candidate
            break
        fi
    done
    if [ -z "$micromamba" ]; then
        mkdir -p "$HOME/bin"
        curl -L https://micro.mamba.pm/api/micromamba/linux-64/latest | tar -xjv -C "$HOME" bin/micromamba
        micromamba=$HOME/bin/micromamba
        [ -x "$micromamba" ] || die "failed to unpack micromamba to $HOME/bin/micromamba"
    fi
    # conda-forge publishes libudev, not eudev.
    pkgs="compilers gcc gxx binutils clang clangxx libclang pkg-config wayland libxkbcommon libxcb alsa-lib libudev"
    if [ ! -d "$prefix/conda-meta" ]; then
        "$micromamba" create -y -p "$prefix" -c conda-forge $pkgs
    else
        "$micromamba" install -y -p "$prefix" -c conda-forge $pkgs
    fi

    echo "=== 3/7 write $envfile ==="
    pc_path="$prefix/lib/pkgconfig:$prefix/share/pkgconfig"
    {
        echo "# Generated by steamdeck_setup.sh. Sourced by BUILD.sh."
        echo "export PATH=\"$prefix/bin:\$HOME/.cargo/bin:\$PATH\""
        echo "export CC=\"$prefix/bin/cc\""
        echo "export CXX=\"$prefix/bin/c++\""
        echo "export PKG_CONFIG=\"$prefix/bin/pkg-config\""
        echo "export PKG_CONFIG_PATH=\"$pc_path\""
        echo "export LIBCLANG_PATH=\"$prefix/lib\""
    } > "$envfile"
    if [ ! -x "$prefix/bin/cc" ] && [ -x "$prefix/bin/gcc" ]; then
        printf 'export CC="%s/bin/gcc"\nexport CXX="%s/bin/g++"\n' "$prefix" "$prefix" >> "$envfile"
    fi
    # shellcheck disable=SC1090
    . "$envfile"
    command -v cc >/dev/null 2>&1 || die "cc still missing after toolchain install"
    command -v pkg-config >/dev/null 2>&1 || die "pkg-config still missing"
    pkg-config --exists wayland-client || die "wayland-client.pc missing (pkg-config path=$PKG_CONFIG_PATH)"
    echo "cc=$(command -v cc)"
    echo "pkg-config=$(command -v pkg-config)"

    echo "=== 4/7 Python venv (numpy / Pillow; no extract-xiso download) ==="
    if [ ! -x "$root/.venv/bin/python" ]; then
        python3 -m venv "$root/.venv"
    fi
    "$root/.venv/bin/pip" install -q numpy==2.2.6 Pillow==11.3.0

    echo "=== 5/7 cargo fetch --locked ==="
    cargo fetch --locked
}

build_game() {
    echo "=== 6/7 compile ==="
    if [ "$rebuild" -eq 0 ] && [ -x "$root/target/release/skate3rust" ] && [ -x "$root/target/release/skate-xiso" ]; then
        echo "binaries already present; skip compile (pass --rebuild to force)"
        return 0
    fi
    ./BUILD.sh
    [ -x "$root/target/release/skate3rust" ] || die "skate3rust missing after BUILD.sh"
    [ -x "$root/target/release/skate-xiso" ] || die "skate-xiso missing after BUILD.sh"
}

find_xex() {
    dir=$1
    if [ -f "$dir/default.xex" ]; then
        printf '%s\n' "$dir/default.xex"
        return 0
    fi
    found=$(find "$dir" -iname 'default.xex' -type f 2>/dev/null | head -n 1)
    [ -n "$found" ] || return 1
    printf '%s\n' "$found"
}

looks_like_ps3() {
    p=$1
    case $p in
        *[Pp][Ss]3*|*EBOOT.BIN*|*eboot.bin*) return 0 ;;
    esac
    if [ -d "$p" ] && { [ -f "$p/EBOOT.BIN" ] || [ -f "$p/PS3_GAME/USRDIR/EBOOT.BIN" ]; }; then
        return 0
    fi
    return 1
}

assets_ready() {
    [ -f "$assets_base/installation.json" ] || return 1
    rel=$(sed -n 's/.*"directory"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$assets_base/installation.json" | head -n 1)
    [ -n "$rel" ] || return 1
    [ -f "$assets_base/$rel/assets/private/game.json" ] || return 1
    [ -f "$assets_base/$rel/assets/private/stock/data/config/input.cfg" ]
}

convert_assets() {
    echo "=== 7/7 convert Xbox 360 disc (local skate-xiso + setup.py) ==="
    if [ "$reconvert" -eq 0 ] && assets_ready; then
        echo "assets already converted under $assets_base; skip (pass --reconvert to force)"
        return 0
    fi
    if [ -z "$source_path" ]; then
        echo
        echo "Need your owned Xbox 360 Skate 3 disc image."
        echo "  • Xbox 360 .iso  OR  extracted default.xex (data/ beside it)"
        echo "  • A PS3 ISO / EBOOT will fail. Skate 2 will fail."
        ask source_path "Path to .iso or default.xex: "
    fi
    source_path=$(expand_path "$source_path")
    [ -e "$source_path" ] || die "not found: $source_path"
    looks_like_ps3 "$source_path" && die "that looks like a PS3 path; this engine needs Xbox 360 Skate 3"

    xex=""
    case $source_path in
        *.iso|*.ISO)
            echo "extracting ISO with target/release/skate-xiso (no GitHub download)"
            mkdir -p "$extract_dir"
            "$root/target/release/skate-xiso" -x "$source_path" -d "$extract_dir"
            xex=$(find_xex "$extract_dir") || die "ISO extracted but default.xex was not found under $extract_dir"
            ;;
        *default.xex|*DEFAULT.XEX)
            xex=$source_path
            ;;
        *)
            if [ -d "$source_path" ]; then
                xex=$(find_xex "$source_path") || die "no default.xex under $source_path"
            else
                die "pass an Xbox 360 .iso or default.xex (got $source_path)"
            fi
            ;;
    esac
    [ -f "$xex" ] || die "default.xex missing: $xex"
    [ -d "$(dirname "$xex")/data" ] || echo "warning: no data/ next to default.xex; conversion may fail" >&2
    echo "converting $xex -> $assets_base"
    "$root/.venv/bin/python" "$root/tools/setup.py" \
        --base "$assets_base" \
        --game-exe "$root/target/release/skate3rust" \
        --source "$xex"
    assets_ready || die "conversion finished but $assets_base is missing game.json / input.cfg (see $assets_base/setup-error.log)"
}

echo "Steam Deck / Linux setup (no sudo)."
echo "repo=$root"
install_toolchain
if [ "$toolchain_only" -eq 1 ]; then
    echo
    echo "toolchain-only done. Run ./BUILD.sh to compile."
    exit 0
fi
build_game
convert_assets

echo
echo "Ready."
echo "  SKATE_ASSETS=$assets_base ./PLAY.sh"
echo
echo "Steam Deck controls: if only the pause menu works, hold ☰ (Start) for two"
echo "seconds to leave Steam desktop keyboard mode, then use the sticks."
echo "A PS3 ISO will not work."
