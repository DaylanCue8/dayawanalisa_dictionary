import CoreGraphics
import Foundation
import UIKit

private struct DayawBox {
  var x0: Int
  var y0: Int
  var x1: Int
  var y1: Int
  var area: Int

  var width: Int { x1 - x0 }
  var height: Int { y1 - y0 }
}

private struct DayawGrayImage {
  let width: Int
  let height: Int
  let pixels: [UInt8]
}

/// iOS first-pass native recognizer. It deliberately shares model framing and
/// HOG math with Android, but does not yet reproduce Python deskew, texture
/// rejection, or Filipino word-list disambiguation.
final class DayawImageRecognizer {
  private let baseClasses = [
    "A", "Ba", "Da", "EI", "Ga", "Ha", "Ka", "La", "Ma",
    "Na", "Nga", "OU", "Pa", "Sa", "Ta", "Wa", "Ya",
  ]
  private let diaClasses = ["Cross", "Dot", "X"]
  private let models: DayawOfflineModels

  init(models: DayawOfflineModels) {
    self.models = models
  }

  func recognize(imageData: Data, inputType: String) throws -> [String: Any] {
    let sessionID = Int(Date().timeIntervalSince1970 * 1000) % 1_000_000_000
    guard let image = try? decode(imageData) else {
      return response(
        text: "", confidence: 0, status: "Invalid_Image", detections: [],
        image: DayawGrayImage(width: 0, height: 0, pixels: []),
        sessionID: sessionID, inputType: inputType
      )
    }
    if laplacianVariance(image.pixels, width: image.width, height: image.height) < 60 {
      return response(
        text: "", confidence: 0, status: "Blurry_Image", detections: [],
        image: image, sessionID: sessionID, inputType: inputType
      )
    }
    let binary = threshold(image.pixels, width: image.width, height: image.height)
    let boxes = segment(binary, width: image.width, height: image.height)

    if boxes.isEmpty {
      return response(
        text: "", confidence: 0, status: "No_Characters", detections: [],
        image: image, sessionID: sessionID, inputType: inputType
      )
    }

    var detections: [[String: Any]] = []
    var pieces: [String] = []
    var confidenceTotal = 0.0

    for box in boxes {
      let crop = crop(binary, width: image.width, box: box)
      let components = segment(crop, width: box.width, height: box.height)
      let baseComponent = components.max { $0.area < $1.area }
      let baseMask = baseComponent.map { mask(crop: crop, width: box.width, for: $0) } ?? crop
      let baseWidth = baseComponent?.width ?? box.width
      let baseHeight = baseComponent?.height ?? box.height
      let baseFeatures = hog(
        normalize(baseMask, width: baseWidth, height: baseHeight), width: 56, height: 56,
        orientations: 9, pixelsPerCell: 8, cellsPerBlock: 2
      )
      let baseResult = try models.classifyDetailed(
        features: baseFeatures, diacriticFeatures: false
      )
      let base = baseClasses.indices.contains(baseResult.classIndex)
        ? baseClasses[baseResult.classIndex] : "Unknown"
      guard base != "Unknown" else { continue }

      var dia = "None"
      var confidence = baseResult.confidence
      var above = false
      if let baseComponent,
         let diaComponent = components.filter({
           $0.x0 != baseComponent.x0 || $0.y0 != baseComponent.y0 ||
           $0.x1 != baseComponent.x1 || $0.y1 != baseComponent.y1
         }).max(by: { $0.area < $1.area }) {
        let diaMask = mask(crop: crop, width: box.width, for: diaComponent)
        let diaFeatures = hog(
          normalize(diaMask, width: diaComponent.width, height: diaComponent.height),
          width: 56, height: 56, orientations: 9, pixelsPerCell: 4, cellsPerBlock: 1
        )
        let diaResult = try models.classifyDetailed(
          features: diaFeatures, diacriticFeatures: true
        )
        dia = diaClasses.indices.contains(diaResult.classIndex) ? diaClasses[diaResult.classIndex] : "Dot"
        confidence = min(confidence, diaResult.confidence)
        above = diaComponent.y0 < baseComponent.y0
      }

      let text: String
      switch base {
      case "EI": text = "{e/i}"
      case "OU": text = "{o/u}"
      case "Da": text = dia == "Cross" || dia == "X" ? "{d/r}" : "{d/r}a"
      case "A": text = "a"
      default:
        let root = String(base.dropLast()).lowercased()
        if dia == "Cross" || dia == "X" {
          text = root
        } else if dia == "Dot" && above {
          text = root + "{e/i}"
        } else if dia == "Dot" {
          text = root + "{o/u}"
        } else {
          text = base.lowercased()
        }
      }
      pieces.append(text)
      confidenceTotal += confidence
      detections.append([
        "char": text,
        "base": base,
        "diacritic": dia,
        "confidence": (confidence * 100).rounded() / 100,
        "is_eligible": true,
        "bbox": ["x0": box.x0, "y0": box.y0, "x1": box.x1, "y1": box.y1],
      ])
    }

    guard !detections.isEmpty else {
      return response(
        text: "", confidence: 0, status: "No_Characters", detections: [],
        image: image, sessionID: sessionID, inputType: inputType
      )
    }
    let confidence = confidenceTotal / Double(detections.count)
    let status = confidence * 100 > 60 ? "Success" : "Low_Confidence"
    let text = pieces.joined().replacingOccurrences(of: "{e/i}", with: "i")
      .replacingOccurrences(of: "{o/u}", with: "u")
      .replacingOccurrences(of: "{d/r}", with: "d")
    let displayText = text.isEmpty ? text : text.prefix(1).uppercased() + String(text.dropFirst())
    return response(
      text: displayText, confidence: confidence * 100,
      status: status, detections: detections, image: image,
      sessionID: sessionID, inputType: inputType
    )
  }

  private func response(
    text: String, confidence: Double, status: String,
    detections: [[String: Any]], image: DayawGrayImage,
    sessionID: Int, inputType: String
  ) -> [String: Any] {
    [
      "translated_text": text,
      "confidence": confidence,
      "status": status,
      "individual_detections": detections,
      "image_width": image.width,
      "image_height": image.height,
      "session_id": sessionID,
      "input_type_used": ["pen", "marker", "pentel_pen"].contains(inputType) ? inputType : "marker",
      "offline": true,
    ]
  }

  private func decode(_ data: Data) throws -> DayawGrayImage {
    guard let source = UIImage(data: data) else {
      throw NSError(domain: "DayawImageRecognizer", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Invalid image"])
    }
    guard let sourceCGImage = source.cgImage else {
      throw NSError(domain: "DayawImageRecognizer", code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "Could not decode image"])
    }
    let pixelSize = CGSize(width: sourceCGImage.width, height: sourceCGImage.height)
    let format = UIGraphicsImageRendererFormat()
    format.scale = 1
    format.opaque = true
    let renderer = UIGraphicsImageRenderer(size: pixelSize, format: format)
    let oriented = renderer.image { _ in
      source.draw(in: CGRect(origin: .zero, size: pixelSize))
    }
    guard let cgImage = oriented.cgImage else {
      throw NSError(domain: "DayawImageRecognizer", code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "Could not decode image"])
    }
    let width = cgImage.width
    let height = cgImage.height
    var pixels = Array(repeating: UInt8(255), count: width * height)
    let colorSpace = CGColorSpaceCreateDeviceGray()
    guard let context = CGContext(data: &pixels, width: width, height: height,
                                  bitsPerComponent: 8, bytesPerRow: width,
                                  space: colorSpace, bitmapInfo: CGImageAlphaInfo.none.rawValue) else {
      throw NSError(domain: "DayawImageRecognizer", code: 3,
                    userInfo: [NSLocalizedDescriptionKey: "Could not create grayscale buffer"])
    }
    context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
    return DayawGrayImage(width: width, height: height, pixels: pixels)
  }

  private func threshold(_ pixels: [UInt8], width: Int, height: Int) -> [UInt8] {
    var histogram = Array(repeating: 0, count: 256)
    pixels.forEach { histogram[Int($0)] += 1 }
    let total = pixels.count
    let sum = histogram.enumerated().reduce(0.0) { $0 + Double($1.offset * $1.element) }
    var backgroundWeight = 0.0
    var backgroundSum = 0.0
    var bestVariance = -1.0
    var threshold = 127
    for value in 0..<256 {
      backgroundWeight += Double(histogram[value])
      guard backgroundWeight > 0 else { continue }
      let foregroundWeight = Double(total) - backgroundWeight
      guard foregroundWeight > 0 else { break }
      backgroundSum += Double(value * histogram[value])
      let meanDifference = backgroundSum / backgroundWeight -
        (sum - backgroundSum) / foregroundWeight
      let variance = backgroundWeight * foregroundWeight * meanDifference * meanDifference
      if variance > bestVariance { bestVariance = variance; threshold = value }
    }
    return pixels.map { $0 <= UInt8(threshold) ? 255 : 0 }
  }

  private func laplacianVariance(_ pixels: [UInt8], width: Int, height: Int) -> Double {
    guard width > 2, height > 2 else { return 0 }
    var values: [Double] = []
    values.reserveCapacity((width - 2) * (height - 2))
    for y in 1..<(height - 1) {
      for x in 1..<(width - 1) {
        let index = y * width + x
        let center = 4.0 * Double(pixels[index])
        let neighbors = Double(pixels[index - width]) + Double(pixels[index + width]) +
          Double(pixels[index - 1]) + Double(pixels[index + 1])
        values.append(center - neighbors)
      }
    }
    let mean = values.reduce(0, +) / Double(values.count)
    return values.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(values.count)
  }

  private func segment(_ binary: [UInt8], width: Int, height: Int) -> [DayawBox] {
    var visited = Array(repeating: false, count: binary.count)
    var boxes: [DayawBox] = []
    let neighbors = [-1, 0, 1].flatMap { dy in [-1, 0, 1].map { dx in (dx, dy) } }
    for y in 0..<height {
      for x in 0..<width where binary[y * width + x] > 0 && !visited[y * width + x] {
        var queue = [(x, y)]
        visited[y * width + x] = true
        var head = 0
        var minX = x, maxX = x, minY = y, maxY = y, area = 0
        while head < queue.count {
          let (cx, cy) = queue[head]; head += 1; area += 1
          minX = min(minX, cx); maxX = max(maxX, cx)
          minY = min(minY, cy); maxY = max(maxY, cy)
          for (dx, dy) in neighbors {
            let nx = cx + dx, ny = cy + dy
            guard nx >= 0, nx < width, ny >= 0, ny < height else { continue }
            let index = ny * width + nx
            if binary[index] > 0 && !visited[index] {
              visited[index] = true; queue.append((nx, ny))
            }
          }
        }
        if area >= 4 { boxes.append(DayawBox(x0: minX, y0: minY, x1: maxX + 1, y1: maxY + 1, area: area)) }
      }
    }
    return mergeMarks(boxes).sorted { $0.y0 == $1.y0 ? $0.x0 < $1.x0 : $0.y0 < $1.y0 }
  }

  private func mergeMarks(_ source: [DayawBox]) -> [DayawBox] {
    guard source.count > 1 else { return source }
    var boxes = source
    let medianHeight = boxes.map(\.height).sorted()[boxes.count / 2]
    var changed = true
    while changed {
      changed = false
      outer: for i in 0..<boxes.count {
        for j in (i + 1)..<boxes.count {
          let first = boxes[i], second = boxes[j]
          let big = max(first.area, second.area), small = min(first.area, second.area)
          let overlap = max(0, min(first.x1, second.x1) - max(first.x0, second.x0))
          let smallerWidth = max(1, min(first.width, second.width))
          let verticalGap = first.y1 <= second.y0 ? second.y0 - first.y1 :
            (second.y1 <= first.y0 ? first.y0 - second.y1 : 0)
          let gapLimit = min(max(first.height, second.height) * 3,
                             max(1, Int(Double(medianHeight) * 2.5)))
          if Double(small) / Double(max(1, big)) <= 0.45 &&
              Double(overlap) / Double(smallerWidth) >= 0.3 && verticalGap <= gapLimit {
            boxes[i] = DayawBox(x0: min(first.x0, second.x0), y0: min(first.y0, second.y0),
                                x1: max(first.x1, second.x1), y1: max(first.y1, second.y1),
                                area: first.area + second.area)
            boxes.remove(at: j)
            changed = true
            break outer
          }
        }
      }
    }
    return boxes
  }

  private func crop(_ binary: [UInt8], width: Int, box: DayawBox) -> [UInt8] {
    (box.y0..<box.y1).flatMap { y in
      (box.x0..<box.x1).map { x in binary[y * width + x] }
    }
  }

  private func mask(crop: [UInt8], width: Int, for box: DayawBox) -> [UInt8] {
    (box.y0..<box.y1).flatMap { y in
      (box.x0..<box.x1).map { x in crop[y * width + x] }
    }
  }

  private func normalize(_ crop: [UInt8], width: Int, height: Int) -> [Double] {
    let margin = Int(0.12 * Double(max(width, height)))
    let side = max(width, height) + 2 * margin
    var square = Array(repeating: UInt8(0), count: side * side)
    let xOffset = (side - width) / 2, yOffset = (side - height) / 2
    for y in 0..<height { for x in 0..<width { square[(y + yOffset) * side + x + xOffset] = crop[y * width + x] } }
    return resizeArea(square, sourceSize: side, targetSize: 56).map { Double($0) / 255.0 }
  }

  private func resizeArea(_ source: [UInt8], sourceSize: Int, targetSize: Int) -> [UInt8] {
    var output = Array(repeating: UInt8(0), count: targetSize * targetSize)
    for y in 0..<targetSize { for x in 0..<targetSize {
      let x0 = Double(x * sourceSize) / Double(targetSize), x1 = Double((x + 1) * sourceSize) / Double(targetSize)
      let y0 = Double(y * sourceSize) / Double(targetSize), y1 = Double((y + 1) * sourceSize) / Double(targetSize)
      var total = 0.0, weight = 0.0
      for sy in Int(floor(y0))...min(sourceSize - 1, Int(ceil(y1)) - 1) {
        for sx in Int(floor(x0))...min(sourceSize - 1, Int(ceil(x1)) - 1) {
          let share = max(0, min(x1, Double(sx + 1)) - max(x0, Double(sx))) * max(0, min(y1, Double(sy + 1)) - max(y0, Double(sy)))
          total += Double(source[sy * sourceSize + sx]) * share; weight += share
        }
      }
      output[y * targetSize + x] = UInt8(max(0, min(255, (total / max(weight, 1e-9)).rounded())))
    }}
    return output
  }

  private func hog(_ image: [Double], width: Int, height: Int, orientations: Int,
                   pixelsPerCell: Int, cellsPerBlock: Int) -> [Double] {
    let transformed = image.map { sqrt(max(0, $0)) }
    var row = Array(repeating: 0.0, count: image.count), col = row
    if height > 2 { for y in 1..<(height - 1) { for x in 0..<width { row[y * width + x] = transformed[(y + 1) * width + x] - transformed[(y - 1) * width + x] } } }
    if width > 2 { for y in 0..<height { for x in 1..<(width - 1) { col[y * width + x] = transformed[y * width + x + 1] - transformed[y * width + x - 1] } } }
    let cells = width / pixelsPerCell, bins = 180.0 / Double(orientations)
    var histogram = Array(repeating: 0.0, count: cells * cells * orientations)
    for y in 0..<(cells * pixelsPerCell) { for x in 0..<(cells * pixelsPerCell) {
      let magnitude = hypot(col[y * width + x], row[y * width + x])
      var angle = atan2(row[y * width + x], col[y * width + x]) * 180.0 / .pi
      if angle < 0 { angle += 180 }
      let bin = min(orientations - 1, Int(angle / bins))
      histogram[((y / pixelsPerCell) * cells + (x / pixelsPerCell)) * orientations + bin] += magnitude / Double(pixelsPerCell * pixelsPerCell)
    }}
    var output: [Double] = []
    for y in 0...(cells - cellsPerBlock) { for x in 0...(cells - cellsPerBlock) {
      var block: [Double] = []
      for by in 0..<cellsPerBlock { for bx in 0..<cellsPerBlock { for bin in 0..<orientations { block.append(histogram[((y + by) * cells + x + bx) * orientations + bin]) } } }
      let firstNorm = sqrt(block.reduce(0) { $0 + $1 * $1 } + 1e-10)
      block = block.map { min($0 / firstNorm, 0.2) }
      let secondNorm = sqrt(block.reduce(0) { $0 + $1 * $1 } + 1e-10)
      output.append(contentsOf: block.map { $0 / secondNorm })
    }}
    return output
  }
}