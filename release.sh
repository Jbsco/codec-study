#!/usr/bin/env bash
# Build and package a release: the release programs and the C library, the version from git describe written into
# the programs, in <out>/<name>-<version>-linux-x86_64.tar.gz with the header, the specification, the README and the
# licenses. Usage: release.sh [out directory, dist when left out] [name]. Needs the Alire toolchain on the PATH.
set -euo pipefail
cd "$(dirname "$0")"
out=${1:-dist}
name=${2:-blockcodec}
version=$(git describe --tags --match 'v*' --abbrev=8 --always --dirty)
work=$(mktemp -d -p "${TMPDIR:-/var/tmp}")
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/version"
printf -- '--  Written by release.sh.\npackage Build_Version is\n   Version : constant String := "%s";\nend Build_Version;\n' \
  "$version" > "$work/version/build_version.ads"
if ! (cd ada && gprbuild -q -P huffman_audio.gpr -XBUILD=release -XVERSION_SOURCE="$work/version" blkc_encode \
      blkc_decode && gprbuild -q -P codec_lib.gpr) > "$work/build.log" 2>&1; then
  cat "$work/build.log" >&2
  exit 1
fi

root=$work/$name-$version
mkdir -p "$root/bin" "$root/lib" "$root/include" "$root/share/doc/$name"
install -m 755 ada/obj-release/blkc-encode ada/obj-release/blkc-decode "$root/bin/"
install -m 755 ada/lib/libblockcodec.so "$root/lib/"
strip "$root/bin/blkc-encode" "$root/bin/blkc-decode"
strip --strip-unneeded "$root/lib/libblockcodec.so"
install -m 644 include/blockcodec.h "$root/include/"
cp README.md docs/spec.md LICENSE LICENSING.md "$root/share/doc/$name/"
cp -r LICENSES "$root/share/doc/$name/"
printf 'Version: %s\nCommit: %s\nBuilt: %s\n' "$version" "$(git rev-parse HEAD)" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$root/BUILD_INFO"
mkdir -p "$out"
tarball=$out/$name-$version-linux-x86_64.tar.gz
tar -czf "$tarball" -C "$work" "$name-$version"
(cd "$out" && sha256sum "$(basename "$tarball")" > "$(basename "$tarball").sha256")
echo "$tarball"
