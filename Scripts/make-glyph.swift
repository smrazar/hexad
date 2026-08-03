import AppKit

// Turn Assets/hexad-glyph.svg into a menu-bar template PDF.
//
// A menu-bar icon must be a *template*: one colour, shape carried by alpha, so macOS inverts it
// for a light or dark menu bar. PDF rather than PNG because the menu bar height varies with the
// display and a vector never softens.
//
// The SVG uses only absolute M/L/C/Z, which is a small enough subset to parse here rather than
// taking a dependency for one build-time conversion.

let root = URL(fileURLWithPath: CommandLine.arguments[0])
    .deletingLastPathComponent().deletingLastPathComponent()
let source = root.appendingPathComponent("Assets/hexad-glyph.svg")
let output = root.appendingPathComponent("build/MenuGlyph.pdf")
try? FileManager.default.createDirectory(at: output.deletingLastPathComponent(),
                                         withIntermediateDirectories: true)

guard let svg = try? String(contentsOf: source, encoding: .utf8) else {
    FileHandle.standardError.write("make-glyph: cannot read \(source.path)\n".data(using: .utf8)!)
    exit(1)
}

// MARK: - Parsing

/// One drawable path: its geometry, and whether the SVG filled or stroked it.
struct Shape {
    let path: CGMutablePath
    let isFilled: Bool
    let strokeWidth: CGFloat
}

func viewBox(_ svg: String) -> CGSize {
    guard let range = svg.range(of: #"viewBox="[^"]+""#, options: .regularExpression) else {
        return CGSize(width: 1000, height: 1000)
    }
    let numbers = svg[range].split(separator: "\"")[1].split(separator: " ").compactMap { Double($0) }
    guard numbers.count == 4 else { return CGSize(width: 1000, height: 1000) }
    return CGSize(width: numbers[2], height: numbers[3])
}

/// Parse one `d` attribute. Absolute M, L, C and Z only — everything this file uses.
func parse(_ d: String) -> CGMutablePath {
    let path = CGMutablePath()
    var numbers: [CGFloat] = []
    var command: Character = " "
    var start = CGPoint.zero
    var current = CGPoint.zero

    func flush() {
        switch command {
        case "M":
            guard numbers.count >= 2 else { break }
            current = CGPoint(x: numbers[0], y: numbers[1])
            start = current
            path.move(to: current)
            // Extra pairs after a moveto are implicit linetos, per the SVG spec.
            var index = 2
            while index + 1 < numbers.count {
                current = CGPoint(x: numbers[index], y: numbers[index + 1])
                path.addLine(to: current)
                index += 2
            }
        case "L":
            var index = 0
            while index + 1 < numbers.count {
                current = CGPoint(x: numbers[index], y: numbers[index + 1])
                path.addLine(to: current)
                index += 2
            }
        case "C":
            var index = 0
            while index + 5 < numbers.count {
                let c1 = CGPoint(x: numbers[index], y: numbers[index + 1])
                let c2 = CGPoint(x: numbers[index + 2], y: numbers[index + 3])
                current = CGPoint(x: numbers[index + 4], y: numbers[index + 5])
                path.addCurve(to: current, control1: c1, control2: c2)
                index += 6
            }
        case "Z":
            path.closeSubpath()
            current = start
        default:
            break
        }
        numbers = []
    }

    var token = ""
    for character in d {
        if character.isLetter {
            if let value = Double(token) { numbers.append(CGFloat(value)) }
            token = ""
            flush()
            command = character
        } else if character == " " || character == "," || character == "\n" {
            if let value = Double(token) { numbers.append(CGFloat(value)) }
            token = ""
        } else {
            token.append(character)
        }
    }
    if let value = Double(token) { numbers.append(CGFloat(value)) }
    flush()
    return path
}

func attribute(_ name: String, in element: String) -> String? {
    // The leading space is load-bearing: without it, looking for `d="` finds the `d="TL"` inside
    // `id="TL"` and the whole glyph parses to an empty path — which produces a valid, blank PDF
    // and no error anywhere.
    guard let range = element.range(of: " \(name)=\"[^\"]*\"", options: .regularExpression)
    else { return nil }
    return String(element[range].split(separator: "\"")[1])
}

var shapes: [Shape] = []
var cursor = svg.startIndex
while let open = svg.range(of: "<path", range: cursor..<svg.endIndex),
      let close = svg.range(of: "/>", range: open.upperBound..<svg.endIndex) {
    let element = String(svg[open.lowerBound..<close.upperBound])
    cursor = close.upperBound
    guard let d = attribute("d", in: element) else { continue }
    let fill = attribute("fill", in: element) ?? "none"
    let width = CGFloat(Double(attribute("stroke-width", in: element) ?? "") ?? 10)
    shapes.append(Shape(path: parse(d), isFilled: fill != "none", strokeWidth: width))
}

guard !shapes.isEmpty else {
    FileHandle.standardError.write("make-glyph: no paths found\n".data(using: .utf8)!)
    exit(1)
}

// The failure this file is most likely to have is silent: a `d` attribute that parses to nothing
// still writes a structurally valid PDF, so the build passes and the menu bar is simply empty.
// Measuring the filled geometry is the one check that catches it.
let filled = shapes.filter(\.isFilled)
let drawnBounds = filled.reduce(CGRect.null) { $0.union($1.path.boundingBox) }
guard !filled.isEmpty, !drawnBounds.isNull, drawnBounds.width > 1, drawnBounds.height > 1 else {
    let message = "make-glyph: parsed \(shapes.count) path(s) but the filled geometry is empty — "
        + "the glyph would be a blank menu bar icon\n"
    FileHandle.standardError.write(message.data(using: .utf8)!)
    exit(1)
}

// MARK: - Drawing

let box = viewBox(svg)
var mediaBox = CGRect(origin: .zero, size: box)
guard let consumer = CGDataConsumer(url: output as CFURL),
      let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
    FileHandle.standardError.write("make-glyph: cannot open \(output.path)\n".data(using: .utf8)!)
    exit(1)
}

context.beginPDFPage(nil)
// SVG's origin is top-left and PDF's is bottom-left, so the whole drawing is flipped once here
// rather than every coordinate being negated as it is parsed.
context.translateBy(x: 0, y: box.height)
context.scaleBy(x: 1, y: -1)

// Everything in one colour. A template image's colour is ignored — only its alpha is read — but
// black is what the shape should be if anything ever renders it directly.
context.setFillColor(NSColor.black.cgColor)
context.setStrokeColor(NSColor.black.cgColor)
context.setLineCap(.round)
context.setLineJoin(.round)

// **Filled paths only — any stroked outline in the artwork is deliberately skipped.**
//
// Two things were tried before this. Filling *and* stroking in one colour merges them into a solid
// blob, because the artwork reads by contrast between a light fill and a dark stroke and a template
// image has no second colour to give it. Stroking the six panels alone gives correct line art at
// large sizes and illegible noise at 18pt, since each panel is a closed path and every shared edge
// is drawn twice.
//
// The filled path is already the whole glyph — the six panels and the centre as separate closed
// subpaths, filled even-odd. That is one silhouette, it survives being 18 points wide, and it is
// what a menu-bar icon is supposed to be.
for shape in filled {
    context.addPath(shape.path)
    context.fillPath(using: .evenOdd)
}

context.endPDFPage()
context.closePDF()
print("    make-glyph: wrote \(output.lastPathComponent) from \(shapes.count) paths")
