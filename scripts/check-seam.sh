#!/bin/sh
# Fails if a portable module imports an Apple-only framework.
# The Linux CI build is the real enforcement; this gives a clear message
# (and catches `#if canImport(AppKit)` leaks the Linux build would skip).
set -eu
cd "$(dirname "$0")/.."
portable="Sources/PondsideCore Sources/PondsideEngrave Sources/PondsideTiming Sources/PondsideLexicon Sources/PondsideBridge Sources/PondsideCLI"
forbidden='^[[:space:]]*(@preconcurrency[[:space:]]+)?import[[:space:]]+(AppKit|Cocoa|SwiftUI|UIKit|CoreGraphics|CoreText|QuartzCore|Metal|MetalKit|CoreImage|AVFoundation|AVFAudio|CoreAudio|CoreServices|Combine|os|OSLog|Darwin|UniformTypeIdentifiers|WebKit)([[:space:]]|$)'
if grep -rEn "$forbidden" $portable; then
  echo "error: Apple-only import below the portability seam (see docs/DESIGN.md)" >&2
  exit 1
fi
# Core is stdlib-only, so it can never grow a Foundation dependency by accident.
if grep -rEn '^[[:space:]]*import[[:space:]]+Foundation' Sources/PondsideCore; then
  echo "error: PondsideCore must not import Foundation" >&2
  exit 1
fi
echo "seam ok"
