#!/usr/bin/env bash

# Build ONLY the platforms you want using Realm's build.sh,
# then (optionally) code-sign the produced XCFrameworks, zip them,
# and print SwiftPM checksums.
# Version names include Xcode version in filename (e.g., Realm.xcframework@26.1.spm.zip)
# Creates checksums.txt file with filename and checksum
# Copies all files to $SCRIPT_START_DIR/Download folder (creates it if doesn't exist)

set -euo pipefail

REPO=""
TAG="" 
OUT=""
PLATFORMS=""
IDENTITY=""
CONFIGURATION="${CONFIGURATION:-Release}"
TAG_DEFAULT="v10.54.6"

# DOWNLOAD_DIR is $SCRIPT_START_DIR/Download
SCRIPT_START_DIR="$(pwd)"
DOWNLOAD_DIR="$SCRIPT_START_DIR/Download"

usage() {
cat << 'USAGE'
Usage: unify_realm_xcframeworks.sh [options]

Options:
  --repo        Path to realm-swift repository (required)
  --tag         Version tag (default: v10.54.6)
  --platforms   If provided: builds all platforms. If empty/omitted: builds iOS only
  --out         Output directory (optional)
  --identity    Code-signing identity (optional)

Examples:
  # Build iOS only (default) - copies to ./Download folder
  ./unify_realm_xcframeworks.sh --repo ./realm-swift

  # Build all platforms - copies to ./Download folder
  ./unify_realm_xcframeworks.sh --repo ./realm-swift --platforms "all"

USAGE
}

# Parse arguments
while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo) REPO="$2"; shift 2 ;;
    --tag) TAG="$2"; shift 2 ;;
    --platforms) PLATFORMS="$2"; shift 2 ;;
    --out) OUT="$2"; shift 2 ;;
    --identity) IDENTITY="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown arg: $1"; usage; exit 1 ;;
  esac
done

# Validate
[[ -z "$TAG" ]] && TAG="$TAG_DEFAULT"
[[ -n "$REPO" ]] || { echo "ERROR: --repo required"; exit 1; }
[[ -d "$REPO" ]] || { echo "ERROR: repo not found: $REPO"; exit 1; }
[[ -f "$REPO/build.sh" ]] || { echo "ERROR: build.sh not found"; exit 1; }

# Check tools
for tool in xcodebuild ditto swift git; do
  command -v "$tool" >/dev/null || { echo "ERROR: Missing $tool"; exit 1; }
done

# Get Xcode version
XCODE_VERSION=$(xcodebuild -version | head -1 | awk '{print $2}')
echo "📱 Detected Xcode version: $XCODE_VERSION"

# Clean build folder
echo "🧹 Cleaning previous build artifacts..."
pushd "$REPO" >/dev/null
if [[ -d "build/$CONFIGURATION" ]]; then
  rm -rf "build/$CONFIGURATION"
  echo "   Removed: build/$CONFIGURATION"
fi
popd >/dev/null

# Build
pushd "$REPO" >/dev/null

echo "⏬ Checking out $TAG..."
git fetch --tags --force --prune --prune-tags >/dev/null 2>&1 || true
git checkout -f --detach "refs/tags/$TAG" >/dev/null 2>&1 || git checkout -f --detach "tags/$TAG"
echo "   On commit: $(git rev-parse --short HEAD)"

# Build logic: empty PLATFORMS = iOS only, otherwise build all
if [[ -z "$PLATFORMS" ]]; then
  echo "🛠️  Building: ./build.sh ios-swift (iOS only)"
  ./build.sh ios-swift
  BUILD_PLATFORM="ios"
else
  echo "🛠️  Building: ./build.sh build (all platforms)"
  ./build.sh build
  BUILD_PLATFORM="universal"
fi

popd >/dev/null

# Set paths based on what was built
if [[ "$BUILD_PLATFORM" == "ios" ]]; then
  ROOT="$REPO/build/$CONFIGURATION/ios"
else
  ROOT="$REPO/build/$CONFIGURATION"
fi

[[ -n "$OUT" ]] || OUT="$ROOT/Universal"
mkdir -p "$OUT"

echo "📁 Using build products in: $ROOT"
echo "📤 Output will go to: $OUT"

# Create checksums file
CHECKSUMS_FILE="$OUT/checksums.txt"
rm -f "$CHECKSUMS_FILE"

# Helper functions
list_slices() {
  local xc="$1"
  if [[ -f "$xc/Info.plist" ]]; then
    echo "   Framework slices:"
    /usr/libexec/PlistBuddy -c 'Print :AvailableLibraries' "$xc/Info.plist" 2>/dev/null | grep -i identifier || true
  fi
}

check_privacy() {
  local xc="$1"
  local count=$(find "$xc" -name "PrivacyInfo.xcprivacy" 2>/dev/null | wc -l)
  if [[ $count -eq 0 ]]; then
    echo "   ⚠️  WARNING: No PrivacyInfo.xcprivacy"
  else
    echo "   ✅ Privacy manifest present"
  fi
}

sign_framework() {
  local path="$1"
  [[ -z "$IDENTITY" ]] && return
  
  command -v codesign >/dev/null || { echo "ERROR: codesign not found"; exit 1; }
  
  echo "   🔏 Signing: $(basename "$path")"
  find "$path" -type d -name "*.framework" 2>/dev/null | while read -r fw; do
    codesign --timestamp -v --force --sign "$IDENTITY" "$fw" 2>/dev/null || true
  done
  codesign --timestamp -v --force --sign "$IDENTITY" "$path" 2>/dev/null || true
}

package_one() {
  local name="$1"
  local src_xc="$ROOT/$name.xcframework"
  
  if [[ ! -d "$src_xc" ]]; then
    echo "❌ ERROR: Framework not found: $src_xc"
    echo "   Expected in: $ROOT"
    ls -la "$ROOT" 2>/dev/null || echo "   Directory does not exist"
    exit 1
  fi
  
  local out_xc="$OUT/$name.xcframework"
  # Include Xcode version in zip filename
  local zip="$OUT/$name.xcframework@${XCODE_VERSION}.spm.zip"
  
  rm -rf "$out_xc" "$zip"
  ditto "$src_xc" "$out_xc"
  
  list_slices "$out_xc"
  check_privacy "$out_xc"
  sign_framework "$out_xc"
  
  ditto -c -k --sequesterRsrc --keepParent "$out_xc" "$zip"
  echo "   ✅ Packaged: $zip"
  
  # Compute and store checksum
  echo -n "   📦 Checksum: "
  local checksum=$(swift package compute-checksum "$zip" 2>/dev/null || echo "N/A")
  echo "$checksum"
  
  # Append to checksums file
  local zip_filename=$(basename "$zip")
  echo "$zip_filename $checksum" >> "$CHECKSUMS_FILE"
}

echo ""
echo "→ Packaging Realm…"
package_one "Realm"

echo ""
echo "→ Packaging RealmSwift…"
package_one "RealmSwift"

echo ""
echo "🎉 Done!"
echo "Files (with Xcode version):"
echo "   $OUT/Realm.xcframework@${XCODE_VERSION}.spm.zip"
echo "   $OUT/RealmSwift.xcframework@${XCODE_VERSION}.spm.zip"
echo ""
echo "📝 Checksums saved to: $CHECKSUMS_FILE"
cat "$CHECKSUMS_FILE"
echo ""

# Copy files to Download folder (create if doesn't exist)
echo "📥 Copying files to: $DOWNLOAD_DIR"
mkdir -p "$DOWNLOAD_DIR"

# Copy the two zip files
cp "$OUT/Realm.xcframework@${XCODE_VERSION}.spm.zip" "$DOWNLOAD_DIR/"
echo "   ✅ Copied: Realm.xcframework@${XCODE_VERSION}.spm.zip"

cp "$OUT/RealmSwift.xcframework@${XCODE_VERSION}.spm.zip" "$DOWNLOAD_DIR/"
echo "   ✅ Copied: RealmSwift.xcframework@${XCODE_VERSION}.spm.zip"

# Copy checksums file
cp "$CHECKSUMS_FILE" "$DOWNLOAD_DIR/checksums.txt"
echo "   ✅ Copied: checksums.txt"

echo ""
echo "📋 Files ready in: $DOWNLOAD_DIR"
echo "   • Realm.xcframework@${XCODE_VERSION}.spm.zip"
echo "   • RealmSwift.xcframework@${XCODE_VERSION}.spm.zip"
echo "   • checksums.txt"
echo ""
echo "📋 Copy-paste into your Package.swift:"
while IFS= read -r line; do
  filename=$(echo "$line" | awk '{print $1}')
  checksum=$(echo "$line" | awk '{print $2}')
  # Extract framework name (remove .xcframework@version.spm.zip)
  framework_name=$(echo "$filename" | sed 's/\.xcframework@.*//')
  echo "   .binaryTarget(name: \"$framework_name\", url: \"<URL>/$filename\", checksum: \"$checksum\"),"
done < "$CHECKSUMS_FILE"

