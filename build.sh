#!/usr/bin/env bash
set -euo pipefail

# Check for dependencies
command -v git >/dev/null 2>&1 || { echo >&2 "ERROR: git not found"; exit 1; }
command -v cmake >/dev/null 2>&1 || { echo >&2 "ERROR: cmake not found"; exit 1; }
command -v ninja >/dev/null 2>&1 || { echo >&2 "ERROR: ninja not found"; exit 1; }
command -v curl >/dev/null 2>&1 || { echo >&2 "ERROR: curl not found"; exit 1; }
command -v unzip >/dev/null 2>&1 || { echo >&2 "ERROR: unzip not found"; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo >&2 "ERROR: python3 not found"; exit 1; }

# Clone Aseprite repo if it doesn't exist
if [ ! -d "aseprite" ]; then
  git clone --recursive --tags https://github.com/aseprite/aseprite.git aseprite || { echo "failed to clone repo"; exit 1; }
else
  git -C aseprite fetch --tags || { echo "failed to fetch repo"; exit 1; }
fi

# Get latest tag if ASEPRITE_VERSION is not set
if [ -z "${ASEPRITE_VERSION:-}" ]; then
  ASEPRITE_VERSION=$(git -C aseprite tag --sort=creatordate | tail -n 1)
fi

echo "Building version $ASEPRITE_VERSION"

# Checkout and clean up
git -C aseprite clean -fdx
git -C aseprite submodule foreach --recursive git clean -xfd
git -C aseprite fetch --depth=1 --no-tags origin "$ASEPRITE_VERSION":"refs/remotes/origin/$ASEPRITE_VERSION" || { echo "failed to fetch repo"; exit 1; }
git -C aseprite reset --hard "origin/$ASEPRITE_VERSION" || { echo "failed to update repo"; exit 1; }
git -C aseprite submodule update --init --recursive || { echo "failed to update submodules"; exit 1; }

# Patch version in CMakeLists.txt
python3 -c "v = open('aseprite/src/ver/CMakeLists.txt').read(); open('aseprite/src/ver/CMakeLists.txt', 'w').write(v.replace('1.x-dev', '$ASEPRITE_VERSION'[1:]))"

# Download Skia
SKIA_TAG_PATH="aseprite/laf/misc/skia-tag.txt"
if [ -f "$SKIA_TAG_PATH" ]; then
  SKIA_VERSION=$(cat "$SKIA_TAG_PATH")
else
  if [[ "$ASEPRITE_VERSION" == *beta* ]]; then
    SKIA_VERSION="m124-08a5439a6b"
  else
    SKIA_VERSION="m102-861e4743af"
  fi
fi

if [ ! -d "skia-$SKIA_VERSION" ]; then
  mkdir "skia-$SKIA_VERSION"
  pushd "skia-$SKIA_VERSION"
  curl -sfLO "https://github.com/aseprite/skia/releases/download/$SKIA_VERSION/Skia-Linux-Release-x64.zip" || { echo "failed to download skia"; exit 1; }
  unzip Skia-Linux-Release-x64.zip
  popd
fi

# Build
rm -rf build

cmake -G Ninja \
  -S aseprite \
  -B build \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
  -DCMAKE_POLICY_DEFAULT_CMP0074=NEW \
  -DCMAKE_POLICY_DEFAULT_CMP0091=NEW \
  -DCMAKE_POLICY_DEFAULT_CMP0092=NEW \
  -DENABLE_CCACHE=OFF \
  -DOPENSSL_USE_STATIC_LIBS=TRUE \
  -DLAF_BACKEND=skia \
  -DSKIA_DIR="$PWD/skia-$SKIA_VERSION" \
  -DSKIA_LIBRARY_DIR="$PWD/skia-$SKIA_VERSION/out/Release-x64" \
  -DSKIA_OPENGL_LIBRARY= \
  || { echo "failed to configure build"; exit 1; }

ninja -C build || { echo "build failed"; exit 1; }

# Create output folder
OUTPUT_DIR="aseprite-$ASEPRITE_VERSION"
mkdir -p "$OUTPUT_DIR"
echo "# This file is here so Aseprite behaves as a portable program" > "$OUTPUT_DIR/aseprite.ini"
cp -r aseprite/docs "$OUTPUT_DIR/"
cp build/bin/aseprite "$OUTPUT_DIR/" || { echo "failed to copy binary"; exit 1; }
cp -r build/bin/data "$OUTPUT_DIR/"

# GitHub Actions export
if [ -n "${GITHUB_WORKFLOW:-}" ]; then
  mkdir -p github
  mv "$OUTPUT_DIR" github/
  echo "ASEPRITE_VERSION=$ASEPRITE_VERSION" >> "$GITHUB_OUTPUT"
fi
