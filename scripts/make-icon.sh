#!/bin/sh
# Build Support/AppIcon.icns from a square source image.
#
# Composes the source onto a Big-Sur-style white squircle (1024pt canvas,
# 824pt rounded rect, r=185), then emits the full iconset size ladder and
# packs it with iconutil. Also writes the composed master to
# Support/icon-1024.png so the icon can be regenerated or tweaked.
#
# Usage: scripts/make-icon.sh path/to/source.{png,jpg}

set -e
SRC="${1:?usage: scripts/make-icon.sh <source-image>}"
MASTER="Support/icon-1024.png"
ICONSET="$(mktemp -d)/AppIcon.iconset"
mkdir -p "$ICONSET" Support

swift - "$SRC" "$MASTER" <<'SWIFT'
import AppKit

let args = CommandLine.arguments
guard args.count == 3, let source = NSImage(contentsOfFile: args[1]),
      let cg = source.cgImage(forProposedRect: nil, context: nil, hints: nil)
else { fatalError("could not read source image") }

let squircle = CGRect(x: 100, y: 100, width: 824, height: 824)
let ctx = CGContext(
    data: nil, width: 1024, height: 1024, bitsPerComponent: 8, bytesPerRow: 0,
    space: CGColorSpace(name: CGColorSpace.sRGB)!,
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
)!
let path = CGPath(roundedRect: squircle, cornerWidth: 185, cornerHeight: 185, transform: nil)
ctx.addPath(path)
ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
ctx.fillPath()
ctx.addPath(path)
ctx.clip()
ctx.interpolationQuality = .high
// The source art carries generous white margins; overdraw the squircle so
// the island fills it at Finder sizes — the clip eats the overflow.
ctx.draw(cg, in: squircle.insetBy(dx: -150, dy: -150))

let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
try! rep.representation(using: .png, properties: [:])!
    .write(to: URL(fileURLWithPath: args[2]))
SWIFT

for size in 16 32 128 256 512; do
  sips -z "$size" "$size" "$MASTER" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
  double=$((size * 2))
  sips -z "$double" "$double" "$MASTER" --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done

iconutil -c icns "$ICONSET" -o Support/AppIcon.icns
rm -rf "$(dirname "$ICONSET")"
echo "Wrote Support/AppIcon.icns (master: $MASTER)"
