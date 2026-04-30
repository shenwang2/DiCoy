#!/usr/bin/env bash
# build_all.sh
# Build DiCoy rootless and rootful .deb packages on a local WSL Ubuntu system
# with Theos installed.
#
# Prerequisites
#   1. WSL2 (Ubuntu 20.04+ recommended)
#   2. Theos installed: https://theos.dev/docs/installation/linux
#   3. $THEOS env var set to your Theos installation root
#   4. iOS 15+ SDK present in $THEOS/sdks/
#   5. ldid and dpkg-deb available (installed by Theos setup)
#
# Usage
#   ./build_all.sh              # build both rootless and rootful
#   ./build_all.sh rootless     # build rootless only
#   ./build_all.sh rootful      # build rootful only
#
# Output
#   packages/rootless/  – rootless .deb  (installs under /var/jb/)
#   packages/rootful/   – rootful  .deb  (installs under /)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# ---------------------------------------------------------------------------
# Validate environment
# ---------------------------------------------------------------------------
if [[ -z "${THEOS:-}" ]]; then
    echo "ERROR: \$THEOS is not set." >&2
    echo "       Install Theos and run: export THEOS=/path/to/theos" >&2
    exit 1
fi
if [[ ! -d "$THEOS" ]]; then
    echo "ERROR: \$THEOS directory not found: $THEOS" >&2
    exit 1
fi
if ! command -v make >/dev/null 2>&1; then
    echo "ERROR: 'make' not found. Install build-essential." >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# Build helper
#   $1 = scheme string ("rootless" or "")
#   $2 = label  ("rootless" or "rootful")
# ---------------------------------------------------------------------------
build_scheme() {
    local scheme="$1"
    local label="$2"
    local out_dir="packages/${label}"

    echo ""
    echo "================================================================"
    echo " Building: ${label}"
    echo "================================================================"

    # Clean previous build artefacts so subproject state is fresh
    make clean 2>/dev/null || true

    # Command-line THEOS_PACKAGE_SCHEME overrides the rootless default
    # exported in the root Makefile; passing an empty string produces rootful.
    make package THEOS_PACKAGE_SCHEME="${scheme}" FINALPACKAGE=1

    # Move/rename output debs into a scheme-specific subdirectory
    mkdir -p "${out_dir}"
    for f in packages/*.deb; do
        [[ -f "$f" ]] || continue
        base=$(basename "$f" .deb)
        dest="${out_dir}/${base}_${label}.deb"
        mv "$f" "$dest"
        echo "  → ${dest}"
    done
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
TARGET="${1:-both}"

case "${TARGET}" in
    rootless)
        build_scheme "rootless" "rootless"
        ;;
    rootful)
        build_scheme "" "rootful"
        ;;
    both)
        build_scheme "rootless" "rootless"
        build_scheme "" "rootful"
        ;;
    *)
        echo "Usage: $0 [rootless|rootful|both]" >&2
        exit 1
        ;;
esac

echo ""
echo "================================================================"
echo " Build complete. Output packages:"
echo "================================================================"
find packages/rootless packages/rootful -name "*.deb" 2>/dev/null | sort
