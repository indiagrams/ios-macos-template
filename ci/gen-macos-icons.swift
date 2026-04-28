// Build a hand-crafted macOS AppIcon.iconset + AppIcon.icns from a 1024 source PNG.
//
// Usage:
//   swift ci/gen-macos-icons.swift <source-1024.png> <appiconset-dir> <output.icns>
//
//   128 / 256 / 512 / 1024  →  high-quality Lanczos downsample (CILanczosScaleTransform)
//                              preserves the hand-drawn gauge artwork.
//   16 / 32 / 64            →  redrawn programmatically with a simplified gauge —
//                              the 1024 source's stroke roughness and "gap" detail
//                              smear into mush below ~80px regardless of sampler.
//
// Why we bypass actool's .icns: actool dedupes the AppIcon catalog by pixel
// resolution and ALWAYS bakes a 4-size .icns (16, 32, 128, 256) into the .app
// regardless of catalog input — so 64/512/1024 never appear in the .icns and
// Finder/Dock at ~50–100px upscales the 32 or downscales the 128 Lanczos
// rough source, defeating the entire point of hand-crafted small icons.
// Documented since 2020: https://mjtsai.com/blog/2020/04/29/actool-strips-larger-icon-sizes/
//
// Pattern (validated 2025):
//   1. Keep AppIcon.appiconset populated with all 10 slots — App Store
//      Connect reads the 1024 marketing icon from Assets.car, and altool
//      validation requires the catalog AppIcon to exist.
//   2. Ship a hand-rolled AppIcon.icns (this script's output) and overwrite
//      actool's bundled copy in a postCompileScript before Code Sign.
//   3. Set Info.plist CFBundleIconFile=AppIcon and DO NOT set CFBundleIconName,
//      so Sonoma/Sequoia consult the .icns rather than the bad Assets.car AppIcon.

import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins

let argv = CommandLine.arguments
guard argv.count == 4 else {
  FileHandle.standardError.write("usage: swift ci/gen-macos-icons.swift <source-1024.png> <appiconset-dir> <output.icns>\n".data(using: .utf8)!)
  exit(2)
}
let sourceURL    = URL(fileURLWithPath: argv[1])
let appiconsetDir = URL(fileURLWithPath: argv[2])
let outputICNS   = URL(fileURLWithPath: argv[3])

guard let nsImage = NSImage(contentsOf: sourceURL),
      let cgSource = nsImage.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
  FileHandle.standardError.write("failed to load \(sourceURL.path)\n".data(using: .utf8)!)
  exit(1)
}
guard cgSource.width >= 1024 && cgSource.height >= 1024 else {
  FileHandle.standardError.write("source must be ≥1024×1024 (got \(cgSource.width)×\(cgSource.height))\n".data(using: .utf8)!)
  exit(1)
}
let ciSource = CIImage(cgImage: cgSource)

func writeOpaquePNG(_ cgImage: CGImage, to url: URL) throws {
  let w = cgImage.width, h = cgImage.height
  let cs = CGColorSpace(name: CGColorSpace.sRGB)!
  let ctx = CGContext(
    data: nil, width: w, height: h,
    bitsPerComponent: 8, bytesPerRow: 0,
    space: cs,
    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
  )!
  ctx.setFillColor(CGColor(gray: 1, alpha: 1)) // sandbox icons must be opaque
  ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
  ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: w, height: h))
  let opaque = ctx.makeImage()!
  let rep = NSBitmapImageRep(cgImage: opaque)
  let png = rep.representation(using: .png, properties: [:])!
  try png.write(to: url)
}

let ciContext = CIContext()
func lanczos(target: Int) -> CGImage {
  let scale = Double(target) / Double(cgSource.width)
  let f = CIFilter.lanczosScaleTransform()
  f.inputImage = ciSource
  f.scale = Float(scale)
  f.aspectRatio = 1
  let out = f.outputImage!
  return ciContext.createCGImage(out, from: CGRect(x: 0, y: 0, width: target, height: target))!
}

// At ≤64px the 1024 source's hand-drawn rough strokes + gap-in-circle detail
// turn to indistinct mush. Redraw with clean primitives at proportional
// stroke widths so the gauge motif reads at every pixel size.
func drawSimplifiedGauge(size: Int) -> CGImage {
  let s = CGFloat(size)
  let cs = CGColorSpace(name: CGColorSpace.sRGB)!
  let ctx = CGContext(
    data: nil, width: size, height: size,
    bitsPerComponent: 8, bytesPerRow: 0,
    space: cs,
    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
  )!
  ctx.setFillColor(CGColor(gray: 1, alpha: 1))
  ctx.fill(CGRect(x: 0, y: 0, width: s, height: s))

  let margin       = max(1, s * 0.16)
  let strokeWidth  = max(1, s * 0.10)
  let center       = CGPoint(x: s / 2, y: s / 2)
  let radius       = (s - 2 * margin) / 2

  ctx.setStrokeColor(CGColor(gray: 0, alpha: 1))
  ctx.setFillColor(CGColor(gray: 0, alpha: 1))
  ctx.setLineCap(.round)
  ctx.setLineJoin(.round)

  ctx.setLineWidth(strokeWidth)
  ctx.strokeEllipse(in: CGRect(x: center.x - radius, y: center.y - radius,
                               width: radius * 2, height: radius * 2))

  // Tapered-wedge needle pointing toward ~2 o'clock (60° CCW from +x axis,
  // matching the 1024 source). Filled triangle/quad so it's visible even at
  // 16×16, where a thin stroke would disappear into AA.
  let angle: CGFloat = 60 * .pi / 180
  let tipDistance = radius * 1.05
  let baseWidth   = max(2, s * 0.22)
  let tipWidth    = max(1, s * 0.05)

  let cosA = cos(angle), sinA = sin(angle)
  let perpX = -sinA, perpY = cosA

  let bL  = CGPoint(x: center.x + perpX * baseWidth/2, y: center.y + perpY * baseWidth/2)
  let bR  = CGPoint(x: center.x - perpX * baseWidth/2, y: center.y - perpY * baseWidth/2)
  let tip = CGPoint(x: center.x + cosA * tipDistance,   y: center.y + sinA * tipDistance)
  let tL  = CGPoint(x: tip.x + perpX * tipWidth/2,      y: tip.y + perpY * tipWidth/2)
  let tR  = CGPoint(x: tip.x - perpX * tipWidth/2,      y: tip.y - perpY * tipWidth/2)

  ctx.beginPath()
  ctx.move(to: bL)
  ctx.addLine(to: tL)
  ctx.addLine(to: tR)
  ctx.addLine(to: bR)
  ctx.closePath()
  ctx.fillPath()

  return ctx.makeImage()!
}

struct Slot {
  let name: String
  let pixels: Int
  let useHandDrawn: Bool
}

let slots: [Slot] = [
  Slot(name: "icon_16x16.png",      pixels: 16,   useHandDrawn: true),
  Slot(name: "icon_16x16@2x.png",   pixels: 32,   useHandDrawn: true),
  Slot(name: "icon_32x32.png",      pixels: 32,   useHandDrawn: true),
  Slot(name: "icon_32x32@2x.png",   pixels: 64,   useHandDrawn: true),
  Slot(name: "icon_128x128.png",    pixels: 128,  useHandDrawn: false),
  Slot(name: "icon_128x128@2x.png", pixels: 256,  useHandDrawn: false),
  Slot(name: "icon_256x256.png",    pixels: 256,  useHandDrawn: false),
  Slot(name: "icon_256x256@2x.png", pixels: 512,  useHandDrawn: false),
  Slot(name: "icon_512x512.png",    pixels: 512,  useHandDrawn: false),
  Slot(name: "icon_512x512@2x.png", pixels: 1024, useHandDrawn: false),
]

// Render to a temp .iconset directory (used by iconutil), and copy each PNG
// into the .appiconset directory so the asset catalog stays in sync.
let tmpDir = URL(fileURLWithPath: NSTemporaryDirectory())
  .appendingPathComponent("anchorkey-iconset-\(ProcessInfo.processInfo.processIdentifier)")
let iconsetDir = tmpDir.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: tmpDir)
try FileManager.default.createDirectory(at: iconsetDir, withIntermediateDirectories: true)
try FileManager.default.createDirectory(at: appiconsetDir, withIntermediateDirectories: true)

var lanczosCache: [Int: CGImage] = [:]
var handDrawnCache: [Int: CGImage] = [:]

for slot in slots {
  let img: CGImage
  let kind: String
  if slot.useHandDrawn {
    if let cached = handDrawnCache[slot.pixels] {
      img = cached
    } else {
      img = drawSimplifiedGauge(size: slot.pixels)
      handDrawnCache[slot.pixels] = img
    }
    kind = "Hand-drawn"
  } else if slot.pixels == cgSource.width {
    img = cgSource
    kind = "Source:    "
  } else {
    if let cached = lanczosCache[slot.pixels] {
      img = cached
    } else {
      img = lanczos(target: slot.pixels)
      lanczosCache[slot.pixels] = img
    }
    kind = "Lanczos:   "
  }

  let iconsetURL    = iconsetDir.appendingPathComponent(slot.name)
  let appiconsetURL = appiconsetDir.appendingPathComponent(slot.name)

  if slot.useHandDrawn {
    let rep = NSBitmapImageRep(cgImage: img)
    let png = rep.representation(using: .png, properties: [:])!
    try png.write(to: iconsetURL)
    try png.write(to: appiconsetURL)
  } else {
    try writeOpaquePNG(img, to: iconsetURL)
    try writeOpaquePNG(img, to: appiconsetURL)
  }

  print("\(kind) \(slot.name)  (\(slot.pixels)×\(slot.pixels))")
}

// iconutil → final .icns (10 entries; bypasses actool's 4-size limit)
let proc = Process()
proc.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
proc.arguments = ["-c", "icns", iconsetDir.path, "-o", outputICNS.path]
try proc.run()
proc.waitUntilExit()
guard proc.terminationStatus == 0 else {
  FileHandle.standardError.write("iconutil failed (exit \(proc.terminationStatus))\n".data(using: .utf8)!)
  exit(1)
}

try? FileManager.default.removeItem(at: tmpDir)
print("wrote \(outputICNS.path)")
print("populated \(appiconsetDir.path)")
