#!/bin/sh
# Builds dist/Oculuxus.app: the release app with the Go helper inside it as
# an auxiliary executable (Contents/MacOS/oculuxus-helper), an Info.plist,
# an icon and an ad-hoc signature. Run from the repository root, usually
# as `make app-bundle`.
#
#   ARCHS    architectures to build, default "arm64 x86_64" (universal)
#   VERSION  CFBundleShortVersionString, default 0.1.0
#   DIST     output directory, default dist
set -eu

ARCHS=${ARCHS:-arm64 x86_64}
VERSION=${VERSION:-0.1.0}
DIST=${DIST:-dist}
BUILD=$(git rev-list --count HEAD 2>/dev/null || echo 1)

app="$DIST/Oculuxus.app"
work="$DIST/.work"
rm -rf "$app" "$work"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources" "$work"
work=$(cd "$work" && pwd)

# The Go helper, one slice per architecture, joined with lipo.
slices=""
for arch in $ARCHS; do
	goarch=$arch
	[ "$arch" = x86_64 ] && goarch=amd64
	echo "==> helper ($arch)"
	(cd helper && CGO_ENABLED=0 GOOS=darwin GOARCH=$goarch go build -trimpath -o "$work/oculuxus-helper-$arch" ./cmd/oculuxus-helper)
	slices="$slices $work/oculuxus-helper-$arch"
done
# shellcheck disable=SC2086
lipo -create $slices -output "$app/Contents/MacOS/oculuxus-helper"

# The app. SwiftPM builds a multi-architecture binary itself when given
# several --arch flags; its products then land under .build/apple.
echo "==> app ($ARCHS)"
archflags=""
for arch in $ARCHS; do archflags="$archflags --arch $arch"; done
# shellcheck disable=SC2086
(cd app && swift build -c release $archflags)
# shellcheck disable=SC2086
bindir=$(cd app && swift build -c release $archflags --show-bin-path)
cp "$bindir/Oculuxus" "$app/Contents/MacOS/Oculuxus"
# Resource bundles of dependencies (swift-protobuf's privacy manifest).
for bundle in "$bindir"/*.bundle; do
	[ -e "$bundle" ] && cp -R "$bundle" "$app/Contents/Resources/"
done

sed -e "s/__VERSION__/$VERSION/" -e "s/__BUILD__/$BUILD/" app/Bundle/Info.plist > "$app/Contents/Info.plist"
printf 'APPL????' > "$app/Contents/PkgInfo"

echo "==> icon"
swift app/Bundle/make-icon.swift "$work/AppIcon.iconset"
iconutil -c icns "$work/AppIcon.iconset" -o "$app/Contents/Resources/AppIcon.icns"

# Ad-hoc signature, helper first, so the bundle's seal covers it. Good
# enough to run on this Mac; distribution needs a Developer ID.
codesign --force --sign - "$app/Contents/MacOS/oculuxus-helper"
codesign --force --sign - "$app"

rm -rf "$work"
echo "==> $app"
for exe in Oculuxus oculuxus-helper; do echo "$exe: $(lipo -archs "$app/Contents/MacOS/$exe")"; done
