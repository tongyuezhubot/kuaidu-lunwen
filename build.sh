#!/bin/bash
set -euo pipefail
project_dir="$(cd "$(dirname "$0")" && pwd)"
bundle="${1:-$project_dir/build/快读论文.app}"
mkdir -p "$bundle/Contents/MacOS" "$bundle/Contents/Resources"
cp "$project_dir/Info.plist" "$bundle/Contents/Info.plist"
cp -R "$project_dir/Resources/." "$bundle/Contents/Resources/"
toolchain_headers="$(xcode-select -p)/usr/include/swift"
compiler_flags=()
if [[ -f "$toolchain_headers/module.modulemap" && -f "$toolchain_headers/bridging.modulemap" ]] && grep -q '^module SwiftBridging' "$toolchain_headers/module.modulemap" && grep -q '^module SwiftBridging' "$toolchain_headers/bridging.modulemap"; then
    # Some Command Line Tools upgrades leave two copies of the same module.
    # The overlay only changes the compiler's view during this build.
    overlay_dir="$(mktemp -d)"
    trap 'rm -rf "$overlay_dir"' EXIT
    touch "$overlay_dir/empty.modulemap"
    cat > "$overlay_dir/overlay.json" <<EOF
{"version":0,"roots":[{"type":"file","name":"$toolchain_headers/module.modulemap","external-contents":"$overlay_dir/empty.modulemap"}]}
EOF
    compiler_flags=(-vfsoverlay "$overlay_dir/overlay.json" -Xcc -ivfsoverlay -Xcc "$overlay_dir/overlay.json")
fi
xcrun swiftc -module-name JianDu "${compiler_flags[@]}" -swift-version 5 -whole-module-optimization -O -target "$(uname -m)-apple-macosx14.0" -module-cache-path "${TMPDIR:-/tmp}/jiandu-fixed-modules" "$project_dir"/Sources/*.swift -o "$bundle/Contents/MacOS/快读论文"
codesign --force --sign - "$bundle"
