#!/bin/bash
set -e

ARCH=$(uname -m)

# fix M1 Mac architecture name
if [ "$ARCH" == "arm64" ]; then
    ARCH=aarch64
fi

BASEDIR="$(cd "$(dirname "$0")" && pwd)"
ZIGDIR=$BASEDIR/.cache/zig
VERSION=$(< build.zig.version)

OS=$(uname)

if [ "$OS" == "Linux" ] ; then
	OS=linux
elif [ "$OS" == "Darwin" ] ; then
	OS=macos
fi


ZIGVER="zig-$OS-$ARCH-$VERSION"
ZIG=$ZIGDIR/$ZIGVER/zig

if [ "$1" == "update" ] ; then
    curl -L --silent https://ziglang.org/download/index.json | jq -r '.master | .version' > build.zig.version
    NEWVERSION=$(< build.zig.version)

    if [ "$VERSION" != "$NEWVERSION" ] ; then
        echo zig version updated from $VERSION to $NEWVERSION
        exit 0
    fi
    echo zig version $VERSION is up-to-date
    exit 0
fi
    
get_zig() {
    (
        mkdir -p "$ZIGDIR"
        cd "$ZIGDIR"
        TARBALL="https://ziglang.org/builds/$ZIGVER.tar.xz"

        if [ ! -d "$ZIGVER" ] ; then
            curl "$TARBALL" | tar -xJ
        fi
    )
}
get_zig

exec $ZIG "$@"
