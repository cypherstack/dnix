#!/usr/bin/env bash
# Builds the Apple targets with the pinned Rust toolchain and the pinned
# Xcode, using the same vendored crates and flags as the pure derivations.
# Runs inside the flake's `apple` shell, which sets DNIX_SETTINGS, DNIX_RUST,
# DNIX_SRC, DNIX_VENDOR, and RUSTC_WRAPPER:
#
#   nix develop .#apple --command dnix-apple-build <output-dir> [target...]
#
# Outputs land in <output-dir>/<target>/ with a SHA256SUMS.apple beside them.
set -euo pipefail

# Nothing from the caller's shell reaches cargo: CARGO_*, CFLAGS, CPATH, and
# the like would change the bytes, and tools from Homebrew or ~/.cargo/bin
# would make build scripts behave differently per Mac. Rerun under an
# environment holding only what the build needs: Xcode's tools and the
# shell's own store paths.
if [ -z "${DNIX_ISOLATED:-}" ]; then
  store_path=""
  while IFS= read -r -d : entry; do
    case "$entry" in /nix/store/*) store_path="$store_path:$entry" ;; esac
  done <<< "$PATH:"
  keep=(
    HOME="$HOME" PATH="/usr/bin:/bin$store_path" TMPDIR="${TMPDIR:-/tmp}"
    RUSTC_WRAPPER="${RUSTC_WRAPPER:?run inside the apple shell}"
    DNIX_SETTINGS="$DNIX_SETTINGS" DNIX_RUST="$DNIX_RUST"
    DNIX_SRC="$DNIX_SRC" DNIX_VENDOR="$DNIX_VENDOR" DNIX_CC_WRAPPER="$DNIX_CC_WRAPPER"
  )
  if [ -n "${DEVELOPER_DIR:-}" ]; then keep+=(DEVELOPER_DIR="$DEVELOPER_DIR"); fi
  if [ -n "${DNIX_ANY_XCODE:-}" ]; then keep+=(DNIX_ANY_XCODE="$DNIX_ANY_XCODE"); fi
  exec env -i DNIX_ISOLATED=1 "${keep[@]}" bash "${BASH_SOURCE[0]}" "$@"
fi

out=${1:?usage: dnix-apple-build <output-dir> [target...]}
shift
settings=${DNIX_SETTINGS:?run inside the apple shell}
name=$(jq -r .name "$settings")
library=$(jq -r .library "$DNIX_RUST")
crate=$(jq -r .crate "$DNIX_RUST")
manifest=$(jq -r .manifest "$DNIX_RUST")

targets=("$@")
if [ ${#targets[@]} -eq 0 ]; then
  while IFS= read -r target; do targets+=("$target"); done \
    < <(jq -r '.targets[] | select(contains("-apple-"))' "$settings")
fi

# The SDK version is embedded in every Mach-O, so the Xcode version is part
# of the reference environment. DNIX_ANY_XCODE=1 builds with whatever
# xcode-select points at, Command Line Tools included; that output is not
# expected to match the reference. Otherwise the pinned Xcode is used: the
# one DEVELOPER_DIR or xcode-select names if it matches, else whichever
# bundle under /Applications reports the pinned version (and build, when
# toolchains.xcodeBuild pins one).
export DEVELOPER_DIR=${DEVELOPER_DIR:-$(xcode-select -p)}
xcode_version() {
  DEVELOPER_DIR=$1 xcodebuild -version 2>/dev/null | awk 'NR == 1 { print $2 }'
}
xcode_build() {
  DEVELOPER_DIR=$1 xcodebuild -version 2>/dev/null | awk 'NR == 2 { print $3 }'
}
xcode_matches() {
  [ "$(xcode_version "$1")" = "$expected_xcode" ] \
    && { [ -z "$expected_build" ] || [ "$(xcode_build "$1")" = "$expected_build" ]; }
}
if [ "${DNIX_ANY_XCODE:-}" = 1 ]; then
  echo "$name: building with the toolchain at $DEVELOPER_DIR, not the pinned Xcode" >&2
else
  expected_xcode=$(jq -r .toolchains.xcode "$settings")
  expected_build=$(jq -r '.toolchains.xcodeBuild // ""' "$settings")
  if ! xcode_matches "$DEVELOPER_DIR"; then
    for candidate in /Applications/Xcode*.app; do
      [ -d "$candidate" ] || continue
      if xcode_matches "$candidate/Contents/Developer"; then
        export DEVELOPER_DIR=$candidate/Contents/Developer
        break
      fi
    done
  fi
  if ! xcode_matches "$DEVELOPER_DIR"; then
    echo "Xcode $expected_xcode${expected_build:+ ($expected_build)} is required and no bundle under /Applications has it; found '$(xcode_version "$DEVELOPER_DIR") ($(xcode_build "$DEVELOPER_DIR"))' at $DEVELOPER_DIR" >&2
    exit 1
  fi
  echo "$name: building with Xcode $(xcode_version "$DEVELOPER_DIR") ($(xcode_build "$DEVELOPER_DIR")) at $DEVELOPER_DIR" >&2
fi

work=$(cd "$(mktemp -d)" && pwd -P)
trap 'rm -rf "$work"' EXIT

# The flake's shell puts nixpkgs' clang on PATH as cc; Apple targets, and the
# build scripts compiled for the host while building them, must use the
# toolchain xcode-select points at instead (/usr/bin comes first on PATH).
# Like the sandboxed targets, the target compilers are wrappers invoked by
# a bare name, so a build that records its compiler records the same name
# on every Mac; see cc-wrapper.sh.
export CC=/usr/bin/cc CXX=/usr/bin/c++ AR=/usr/bin/ar
mkdir -p "$work/bin"
export PATH=$work/bin:$PATH
while IFS= read -r apple_target; do
  variable=${apple_target//-/_}
  upper=$(printf '%s' "$variable" | tr '[:lower:]' '[:upper:]')
  for pair in "cc:/usr/bin/cc" "c++:/usr/bin/c++"; do
    printf '#!/bin/bash\nexec %s %s -- "$@"\n' "$DNIX_CC_WRAPPER" "${pair#*:}" > "$work/bin/dnix-${pair%%:*}-$apple_target"
    chmod +x "$work/bin/dnix-${pair%%:*}-$apple_target"
  done
  export "CC_$variable=dnix-cc-$apple_target" "CXX_$variable=dnix-c++-$apple_target" "AR_$variable=/usr/bin/ar"
  export "CARGO_TARGET_${upper}_LINKER=/usr/bin/cc"
done < <(jq -r '.targets[] | select(contains("-apple-"))' "$settings")

cp -RL "$DNIX_VENDOR" "$work/vendor"
chmod -R u+w "$work/vendor"
# The flake already filtered the workspace (no target at its root, no .git).
cp -RL "$DNIX_SRC" "$work/src"
chmod -R u+w "$work/src"

# importCargoLock's configuration serves every crate from the vendored
# set, git sources included, with a placeholder for the vendor directory.
export CARGO_HOME=$work/cargo-home
mkdir -p "$CARGO_HOME"
sed "s|cargo-vendor-dir|$work/vendor|" "$work/vendor/.cargo/config.toml" > "$CARGO_HOME/config.toml"

export SOURCE_DATE_EPOCH=0
export MACOSX_DEPLOYMENT_TARGET="$(jq -r .floors.macos "$settings").0"
export IPHONEOS_DEPLOYMENT_TARGET="$(jq -r .floors.ios "$settings").0"

# The catch-all comes first: rustc and clang take the last matching prefix.
# It covers cargo's target directory, whose path otherwise reaches code that
# build scripts generate.
workspace_prefix=$(jq -r .paths.workspace "$settings")
registry_prefix=$(jq -r '.paths.registry + "/" + .paths.registryIndex' "$settings")
remaps=("$work=/build" "$work/src=$workspace_prefix" "$work/vendor=$registry_prefix")
rustflags=()
# Flags that name directories go to the compiler wrappers, not into CFLAGS.
ccargs=()
for remap in "${remaps[@]}"; do
  rustflags+=("--remap-path-prefix=$remap")
  ccargs+=("-ffile-prefix-map=$remap")
done
export DNIX_BUILD_ROOT=$work
DNIX_CC_ARGS=$(printf '%s\n' "${ccargs[@]}")
export DNIX_CC_ARGS
# Variables the package adds, from dnix.json.
while IFS= read -r assignment; do
  [ -n "$assignment" ] && export "$assignment"
done < <(jq -r '.rust.env // {} | to_entries[] | "\(.key)=\(.value)"' "$settings")
# Location-independent install name with room for tools that rewrite it
# to an absolute path (dart test does), no post-link strip, and no debug
# map from the linker.
rustflags+=(
  "-Clink-arg=-Wl,-install_name,@rpath/lib$library.dylib"
  "-Clink-arg=-Wl,-headerpad_max_install_names"
  "-Cstrip=none"
  "-Clink-arg=-Wl,-S"
)
export CARGO_ENCODED_RUSTFLAGS
CARGO_ENCODED_RUSTFLAGS=$(IFS=$'\x1f'; printf '%s' "${rustflags[*]}")

# Cargo reads configuration from the working directory upwards; only the
# copied workspace may contribute any.
cd "$work/src"
for target in "${targets[@]}"; do
  # The flags the package adds for this target, from dnix.json. The cc
  # crate reads CXXFLAGS for C++ sources, not CFLAGS.
  cflags=$(jq -r --arg t "$target" '.rust.cflags[$t] // [] | join(" ")' "$settings")
  export "CFLAGS_${target//-/_}=$cflags" "CXXFLAGS_${target//-/_}=$cflags"
  cargo build --locked --offline --release --lib --package "$crate" \
    --manifest-path "$work/src/$manifest" \
    --target "$target" --target-dir "$work/target"
  mkdir -p "$out/$target"
  for built in "$work/target/$target/release/lib$library.dylib" "$work/target/$target/release/lib$library.a"; do
    [ -e "$built" ] || continue
    # Remapping covers paths the compiler records, not strings a crate
    # makes from env!("CARGO_MANIFEST_DIR") or env!("OUT_DIR").
    if grep -a -q -F "$work" "$built"; then
      echo "$built embeds the build directory; a crate turns its manifest or output directory into a string, which no remap can fix" >&2
      exit 1
    fi
    cp "$built" "$out/$target/"
  done
done

(cd "$out" && find . -type f -path './*-apple-*' | sort | xargs shasum -a 256 > SHA256SUMS.apple)
echo "Wrote $out/SHA256SUMS.apple"
