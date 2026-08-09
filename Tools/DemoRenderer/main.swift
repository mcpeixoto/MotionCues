//
//  DemoRenderer — generates the demo asset for the README and for social posts.
//
//  WHAT THIS IS, PRECISELY
//  ----------------------
//  It is NOT a screen recording. Producing one needs macOS Screen Recording
//  permission, which was not available on the machine this was made on.
//
//  What it *is*: the app's real motion pipeline, rendered to a file.
//
//    * `SimulatedMotionProvider` produces device-frame samples at 100 Hz —
//      the same provider the shipping app uses for its Simulator source, with
//      the same deliberately misaligned sensor orientation and the same
//      band-limited road vibration.
//    * `MotionEngine` resolves the reference frame, estimates the vehicle's
//      forward axis, removes bias, and runs the One Euro filters — untouched.
//    * `LayerDotRenderer` positions the dots — the same class the overlay uses,
//      including the per-dot gain variation and the critically damped springs.
//
//  So every dot position in the output is the genuine output of the shipping
//  code. The only fabricated part is the desktop behind the dots, which is a
//  static PNG mockup rendered from Tools/Backdrop/backdrop.html.
//
//  Everything is deterministic: `SplitMix64` is seeded, and frames are stepped
//  at a fixed dt rather than by a display link, so re-running produces an
//  identical sequence.
//
//  Usage:
//      DemoRenderer <backdrop.png> <output-dir> [seconds] [fps]
//

import AppKit
import QuartzCore

// MARK: - Arguments

let args = CommandLine.arguments
guard args.count >= 3 else {
    FileHandle.standardError.write(
        "usage: DemoRenderer <backdrop.png> <output-dir> [seconds] [fps]\n".data(using: .utf8)!)
    exit(2)
}
let backdropPath = args[1]
let outputDir = URL(fileURLWithPath: args[2], isDirectory: true)
let duration = args.count > 3 ? Double(args[3]) ?? 24 : 24
let fps = args.count > 4 ? Double(args[4]) ?? 30 : 30

guard let backdrop = NSImage(contentsOfFile: backdropPath),
      let backdropCG = backdrop.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
    FileHandle.standardError.write("cannot read backdrop at \(backdropPath)\n".data(using: .utf8)!)
    exit(1)
}

// Point size of the "screen" we are drawing, and the pixel scale of the output.
let pointSize = CGSize(width: 1470, height: 956)
let scale = CGFloat(backdropCG.width) / pointSize.width   // 2.0 for the @2x mockup
let pixelSize = CGSize(width: pointSize.width * scale, height: pointSize.height * scale)

try? FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)

// MARK: - The real pipeline

var settings = RenderSettings()
// Bigger and more opaque than the app's defaults, because a 9 pt dot at 45%
// opacity disappears in a compressed, autoplaying timeline video. The *gain*
// is untouched at the app's real High setting — the dots are easier to see,
// they do not move further than they really would.
settings.dotsPerEdge = 7
settings.dotDiameter = 15
settings.opacity = 0.95
settings.edgeInset = 40
settings.gain = CueIntensity.high.gain     // disclosed in the alt text
settings.placement = .sides
settings.appearance = .dark                // light dots, this backdrop is dark
settings.verticalCues = true
settings.springOmega = 18
settings.idleFadeEnabled = true

let engine = MotionEngine()
engine.smoothing = 0.45
engine.sensitivity = 0.6

// The layer tree the renderer draws into. Not attached to any window — we
// render it straight into a bitmap context each frame.
let root = CALayer()
root.frame = CGRect(origin: .zero, size: pointSize)
root.contentsScale = scale
let renderer = LayerDotRenderer(root: root)
renderer.configure(settings: settings, size: pointSize, scale: scale, isDark: true)

// Drive the simulator synchronously rather than through its dispatch timer, so
// the output is frame-exact and reproducible.
let provider = SimulatedMotionProvider()
var pending: [MotionFrame] = []
provider.onFrame = { pending.append($0) }

let sensorHz = MotionCuesService.sensorRateHz
let sensorDt = 1.0 / sensorHz
let frameDt = 1.0 / fps
let sensorStepsPerFrame = Int((frameDt / sensorDt).rounded())
let totalFrames = Int(duration * fps)

// Let the engine's calibration converge before the first exported frame, the
// same way it would after twenty seconds of real driving.
let warmupFrames = Int(26 * fps)

FileHandle.standardError.write(
    "warming up \(warmupFrames) frames, then rendering \(totalFrames) at \(Int(fps)) fps\n"
        .data(using: .utf8)!)

engine.beginCalibration(duration: 24)

let colorSpace = CGColorSpaceCreateDeviceRGB()
var written = 0

for frameIndex in 0..<(warmupFrames + totalFrames) {
    // Advance the sensor stream.
    for _ in 0..<sensorStepsPerFrame {
        provider.step()
    }
    for f in pending { engine.ingest(f) }
    pending.removeAll(keepingCapacity: true)

    // Advance the visual state.
    let motion = engine.state.load()
    let offset = DotLayout.offset(for: motion, settings: settings)
    let emphasis = min(1.0, motion.magnitude / 0.25)
    renderer.render(offset: offset, emphasis: emphasis, dt: frameDt)

    guard frameIndex >= warmupFrames else { continue }

    // Composite: backdrop, then the real dot layers on top.
    guard let ctx = CGContext(data: nil,
                              width: Int(pixelSize.width),
                              height: Int(pixelSize.height),
                              bitsPerComponent: 8,
                              bytesPerRow: 0,
                              space: colorSpace,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
        FileHandle.standardError.write("cannot make bitmap context\n".data(using: .utf8)!)
        exit(1)
    }
    ctx.draw(backdropCG, in: CGRect(origin: .zero, size: pixelSize))
    ctx.saveGState()
    ctx.scaleBy(x: scale, y: scale)
    // Rest-position marks first, so the dots sit on top of their own reference.
    Annotations.drawRestMarks(DotLayout.positions(in: pointSize, settings: settings),
                              diameter: CGFloat(settings.dotDiameter), in: ctx)
    root.render(in: ctx)
    Annotations.drawPanel(motion: motion, in: ctx, canvas: pointSize)
    Annotations.drawCaption("Dots move opposite to the car, like a loose object on the dashboard",
                            in: ctx, canvas: pointSize)
    ctx.restoreGState()

    guard let image = ctx.makeImage() else { continue }
    let rep = NSBitmapImageRep(cgImage: image)
    guard let png = rep.representation(using: .png, properties: [:]) else { continue }
    let name = String(format: "frame-%05d.png", written)
    try? png.write(to: outputDir.appendingPathComponent(name))
    written += 1

    if written % 30 == 0 {
        FileHandle.standardError.write("  \(written)/\(totalFrames)\n".data(using: .utf8)!)
    }
}

FileHandle.standardError.write("wrote \(written) frames to \(outputDir.path)\n".data(using: .utf8)!)
