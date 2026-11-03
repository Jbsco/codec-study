#!/usr/bin/env bash
# Update a clone of an AUR package to a release: pkgver, pkgrel 1 and the release tarball's sha256 in the PKGBUILD,
# .SRCINFO written again, the package built from the release to check it, and the change committed. With --push the
# commit goes to the clone's origin. Runs as a user that may run makepkg, not root.
# Usage: aur.sh <package clone> <version, no leading v> <sha256> [--push]
set -euo pipefail
dir=$1 version=$2 sha=$3 push=${4:-}
cd "$dir"
name=$(sed -n 's/^pkgname=//p' PKGBUILD)
if [ "$(sed -n 's/^pkgver=//p' PKGBUILD)" = "$version" ] && grep -qx "sha256sums=('$sha')" PKGBUILD; then
  echo "aur.sh: $name $version is already packaged"
  exit 0
fi
sed -i -e "s/^pkgver=.*/pkgver=$version/" -e "s/^pkgrel=.*/pkgrel=1/" -e "s/^sha256sums=(.*)$/sha256sums=('$sha')/" PKGBUILD
grep -qx "sha256sums=('$sha')" PKGBUILD
makepkg --printsrcinfo > .SRCINFO
work=$(mktemp -d -p "${TMPDIR:-/var/tmp}")
trap 'rm -rf "$work"' EXIT
if ! BUILDDIR=$work/build SRCDEST=$work/src PKGDEST=$work/out makepkg -f --noconfirm > "$work/makepkg.log" 2>&1; then
  cat "$work/makepkg.log"
  exit 1
fi
git add PKGBUILD .SRCINFO
git commit -q -m "Update $name to $version"
echo "aur.sh: $name $version built and committed"
if [ "$push" = --push ]; then
  git push -q origin HEAD:master
  echo "aur.sh: pushed"
fi
