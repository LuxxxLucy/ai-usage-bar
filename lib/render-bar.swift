import AppKit
import Foundation

let args = CommandLine.arguments
guard args.count >= 7 else {
    fputs("usage: render-bar <active:0|1> <q1> <q2> <q3> <c1> <c2> [font-name]\n", stderr)
    exit(1)
}

let isActive = args[1] == "1"
let quotaLines = [args[2], args[3], args[4]]
let creditLines = [args[5], args[6]]
let fontName = args.count >= 8 ? args[7] : "BerkeleyMono-Bold"

func makeFont(_ size: CGFloat) -> NSFont {
    NSFont(name: fontName, size: size)
        ?? NSFont.monospacedSystemFont(ofSize: size, weight: .bold)
}

let qFont = makeFont(7.8)
let cFont = makeFont(8.0)

let labelColor = NSColor(white: 1.0, alpha: 0.72)
let valueColor = NSColor(white: 1.0, alpha: 1.0)
let staleColor = NSColor(white: 1.0, alpha: 0.55)
let dividerColor = NSColor(white: 1.0, alpha: 0.28)

func styled(_ text: String, font: NSFont) -> NSAttributedString {
    let isMuted = text.hasPrefix("⏳") || text.hasPrefix("⚠") || text.hasSuffix("--") || text.hasSuffix("no key")
    let out = NSMutableAttributedString(string: text, attributes: [
        .font: font,
        .foregroundColor: isMuted ? staleColor : valueColor,
    ])
    if !isMuted, let colon = text.firstIndex(of: ":") {
        let len = text.distance(from: text.startIndex, to: colon) + 1
        out.addAttribute(.foregroundColor, value: labelColor, range: NSRange(location: 0, length: len))
    }
    return out
}

let qAttr = quotaLines.map { styled($0, font: qFont) }
let cAttr = creditLines.map { styled($0, font: cFont) }

let qWidth = qAttr.map { $0.size().width }.max() ?? 0
let cWidth = cAttr.map { $0.size().width }.max() ?? 0

let heightPt: CGFloat = 24
let scale: CGFloat = 2
let padLeft: CGFloat = 3
let dotDia: CGFloat = 7
let dotGap: CGFloat = 6
let divPad: CGFloat = 6
let divW: CGFloat = 0.5
let padRight: CGFloat = 3

let qX = padLeft + dotDia + dotGap
let divX = ceil(qX + qWidth + divPad)
let cX = divX + divW + divPad
let widthPt = ceil(cX + cWidth + padRight)

guard let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil,
    pixelsWide: Int(widthPt * scale),
    pixelsHigh: Int(heightPt * scale),
    bitsPerSample: 8,
    samplesPerPixel: 4,
    hasAlpha: true,
    isPlanar: false,
    colorSpaceName: .deviceRGB,
    bytesPerRow: 0,
    bitsPerPixel: 0
) else {
    exit(1)
}
rep.size = NSSize(width: widthPt, height: heightPt)

NSGraphicsContext.saveGraphicsState()
guard let ctx = NSGraphicsContext(bitmapImageRep: rep) else { exit(1) }
NSGraphicsContext.current = ctx
ctx.shouldAntialias = true

// 1. Left activity dot (vertically centered)
let dotRect = NSRect(x: padLeft, y: (heightPt - dotDia) / 2, width: dotDia, height: dotDia)
let dotPath = NSBezierPath(ovalIn: dotRect)
if isActive {
    NSColor(calibratedRed: 1.0, green: 0.23, blue: 0.19, alpha: 1.0).setFill()
    dotPath.fill()
} else {
    NSColor(white: 1.0, alpha: 0.35).setStroke()
    dotPath.lineWidth = 1.2
    dotPath.stroke()
}

// 2. Left 3-line quota block (vertically centered by capHeight)
let qCap = qFont.capHeight
let qDesc = abs(qFont.descender)
let qGap: CGFloat = 1.6
let qTotalH = qCap * 3 + qGap * 2
let qBottomBase = (heightPt - qTotalH) / 2
for (i, attr) in qAttr.enumerated() {
    let rowFromBottom = CGFloat(2 - i)
    let baseY = qBottomBase + rowFromBottom * (qCap + qGap)
    attr.draw(at: NSPoint(x: qX, y: baseY - qDesc))
}

// 3. Subtle vertical divider
dividerColor.setFill()
let divH: CGFloat = 16
NSRect(x: divX, y: (heightPt - divH) / 2, width: divW, height: divH).fill()

// 4. Right 2-line credits block (vertically centered by capHeight)
let cCap = cFont.capHeight
let cDesc = abs(cFont.descender)
let cGap: CGFloat = 3.0
let cTotalH = cCap * 2 + cGap
let cBottomBase = (heightPt - cTotalH) / 2
for (i, attr) in cAttr.enumerated() {
    let rowFromBottom = CGFloat(1 - i)
    let baseY = cBottomBase + rowFromBottom * (cCap + cGap)
    attr.draw(at: NSPoint(x: cX, y: baseY - cDesc))
}

NSGraphicsContext.restoreGraphicsState()

guard let png = rep.representation(using: .png, properties: [:]) else { exit(1) }
print(png.base64EncodedString())
