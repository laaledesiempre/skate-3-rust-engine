# Linux build

The game builds and runs on Linux (glibc and musl). Vulkan is required;
wgpu uses the system Vulkan driver (Mesa RADV, NVIDIA, etc.).

## System dependencies

- wayland / libxcb / libxkbcommon (winit)
- alsa-lib (audio)
- libudev / eudev (gamepad enumeration via gilrs)
- clang + libclang (bindgen in dependency build scripts)

## Build

```sh
./BUILD.sh
```

Or directly:

```sh
cargo build --release -p skate-game -p skate-steam-relay -p skate-xiso
```

Then `./PLAY.sh`. If `target/release/skate3rust` is missing, `PLAY.sh` runs
`cargo build` and launches the debug binary. `SKATE_ASSETS` may be a
`tools/setup.py --base` directory (`installation.json`) or the inner
`installations/<id>/assets` tree.

Notes:

- **musl**: rustup's musl target defaults to static-pie, but musl distros
  generally do not ship static wayland/alsa libraries. BUILD.sh detects musl
  via `ldd` and exports `RUSTFLAGS="-C target-feature=-crt-static"` to link
  dynamically against musl.
- **`dev-dynamic` (bevy dynamic linking)** is a default feature aimed at
  Windows dev builds. On Linux, and especially on musl, build with
  `--no-default-features` (Steam lobby support lives behind the default
  `steam` feature and is also dropped; direct UDP multiplayer still works,
  and the steamworks SDK only ships glibc binaries anyway).
- **Setup**: the packaged `skate3setup` helper is a PyInstaller executable
  built for Windows/glibc. On Linux run the pipeline with the system Python
  (`tools/setup.py`, needs numpy/pillow/tkinter). A `support/skate3setup`
  shim next to the game binary can simply exec it.
- **ISO extraction**: `skate-xiso` (workspace crate, xdvdfs-based) extracts
  Xbox 360 ISOs natively; the pipeline prefers it over the extract-xiso
  download. A pre-extracted game folder (`default.xex` + `data/`) also works.

## Steam Deck

SteamOS has no compiler by default and the `deck` user often has no sudo.
`./steamdeck_setup.sh` (or `./setup.sh`) installs rustup and a home-folder
micromamba toolchain under `$HOME/ccenv` (`libudev`, not `eudev`), fetches
crates (`cargo fetch` has no `-p`), runs `./BUILD.sh`, extracts an Xbox 360
ISO with `skate-xiso`, and converts assets with `tools/setup.py`.

```sh
./steamdeck_setup.sh --source /path/to/skate3-360.iso
SKATE_ASSETS=$HOME/skate3-assets ./PLAY.sh
```

`--source` can be an Xbox 360 `.iso` or an extracted `default.xex` (keep
`data/` beside it). A PS3 ISO will not convert. `--toolchain-only` stops
after rustup/micromamba/fetch.

Piped bootstrap clones the repo, then re-execs from the checkout so prompts
use the TTY:

```sh
curl -fsSL https://raw.githubusercontent.com/SK8-ENGINE/skate-3-rust-engine/main/steamdeck_setup.sh | sh
```

Until this is merged, pin the branch that contains the script and set
`SKATE_DECK_REPO` / `SKATE_DECK_BRANCH` if you are not cloning `main`.

## Gamepads

Non-Windows input uses gilrs with its default filters disabled (raw axes,
matching what the TU3 input converter expects). Controller layouts come from
an embedded copy of SDL_GameControllerDB, plus extra Steam Deck GUID versions.
Users can override mappings via `SDL_GAMECONTROLLERCONFIG`.

On Steam Deck **desktop mode**, Steam's background client puts the built-in
pad in keyboard/mouse layout ("lizard mode"). Escape/Start still open the
pause menu; sticks do nothing. Hold **☰ (Start) for about two seconds** to
switch to the gamepad action set. `PLAY.sh` prints this hint. The runtime
prefers a mapped Steam Deck / Xbox node over touchpad/keyboard evdev devices.

## macOS (Apple Silicon, untested by us)

Contributed from #7, tested by its author on an M3: on macOS wgpu's Vulkan
backend compiles behind `vulkan-portability` (MoltenVK), and materials use
the non-bindless path (`BUFFER_BINDING_ARRAY` disabled, because MoltenVK
lacks robustBufferAccess2). Launch with `MVK_CONFIG_FAST_MATH_ENABLED=0` —
with fast-math on, the depth prepass and the main pass disagree on skinned,
morphed customiser skaters and render them as black-and-white patches.
