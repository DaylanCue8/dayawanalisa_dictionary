import Foundation

private struct DayawBinaryReader {
  let data: Data
  var offset = 0

  mutating func readBytes(_ count: Int) -> Data {
    let end = offset + count
    guard end <= data.count else { fatalError("Truncated Dayaw model") }
    defer { offset = end }
    return data.subdata(in: offset..<end)
  }

  mutating func readUInt8() -> UInt8 {
    readBytes(1).first!
  }

  mutating func readUInt32() -> UInt32 {
    readBytes(4).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
  }

  mutating func readUInt64() -> UInt64 {
    readBytes(8).withUnsafeBytes { $0.loadUnaligned(as: UInt64.self) }
  }

  mutating func readString() -> String {
    String(data: readBytes(Int(readUInt32())), encoding: .ascii)!
  }
}

private struct DayawArray {
  let type: UInt8
  let shape: [Int]
  let bytes: Data

  var count: Int {
    shape.reduce(1, *)
  }

  func floats() -> [Float] {
    if type == 1 {
      return bytes.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    }
    return bytes.withUnsafeBytes {
      $0.bindMemory(to: Double.self).map(Float.init)
    }
  }

  func doubles() -> [Double] {
    if type == 2 {
      return bytes.withUnsafeBytes { Array($0.bindMemory(to: Double.self)) }
    }
    return bytes.withUnsafeBytes {
      $0.bindMemory(to: Float.self).map(Double.init)
    }
  }

  func integers() -> [Int] {
    bytes.withUnsafeBytes {
      $0.bindMemory(to: Int64.self).map(Int.init)
    }
  }
}

final class DayawSVM {
  private let supportVectors: [Float]
  private let dualCoefficient: [Double]
  private let intercept: [Double]
  private let supportCount: [Int]
  private let gamma: Double
  private let classes: [Int]
  private let featureCount: Int
  private let supportVectorCount: Int

  init(resourceName: String) throws {
    guard let url = Bundle.main.url(forResource: resourceName, withExtension: "bin") else {
      throw NSError(domain: "DayawSVM", code: 1, userInfo: [NSLocalizedDescriptionKey: "Missing model resource \(resourceName).bin"])
    }
    let data = try Data(contentsOf: url)
    var reader = DayawBinaryReader(data: data)
    guard reader.readBytes(8) == Data("DAYAWNP1".utf8) else {
      throw NSError(domain: "DayawSVM", code: 2, userInfo: [NSLocalizedDescriptionKey: "Invalid Dayaw model header"])
    }

    var arrays: [String: DayawArray] = [:]
    for _ in 0..<reader.readUInt32() {
      let name = reader.readString()
      let type = reader.readUInt8()
      let dimensions = Int(reader.readUInt8())
      let shape = (0..<dimensions).map { _ in Int(reader.readUInt64()) }
      let byteCount = Int(reader.readUInt64())
      arrays[name] = DayawArray(type: type, shape: shape, bytes: reader.readBytes(byteCount))
    }

    supportVectors = arrays["support_vectors"]!.floats()
    dualCoefficient = arrays["dual_coef"]!.doubles()
    intercept = arrays["intercept"]!.doubles()
    supportCount = arrays["n_support"]!.integers()
    gamma = arrays["gamma"]!.doubles()[0]
    classes = arrays["classes"]!.integers()
    featureCount = arrays["support_vectors"]!.shape[1]
    supportVectorCount = arrays["support_vectors"]!.shape[0]
  }

  func predict(features: [Double]) -> (classIndex: Int, classValue: Int) {
    let result = predictWithConfidence(features: features)
    return (result.classIndex, result.classValue)
  }

  func predictWithConfidence(features: [Double]) -> (
    classIndex: Int,
    classValue: Int,
    confidence: Double
  ) {
    precondition(features.count == featureCount)
    let classCount = supportCount.count
    let starts = supportCount.reduce(into: [0]) { result, count in
      result.append(result.last! + count)
    }
    var votes = Array(repeating: 0, count: classCount)
    var pair = 0

    for first in 0..<classCount {
      for second in (first + 1)..<classCount {
        var decision = intercept[pair]
        for support in starts[first]..<(starts[first] + supportCount[first]) {
          decision += kernel(features: features, support: support) * dualCoefficient[(second - 1) * supportVectorCount + support]
        }
        for support in starts[second]..<(starts[second] + supportCount[second]) {
          decision += kernel(features: features, support: support) * dualCoefficient[first * supportVectorCount + support]
        }
        if decision > 0 {
          votes[first] += 1
        } else {
          votes[second] += 1
        }
        pair += 1
      }
    }

    let rankedVotes = votes.sorted(by: >)
    let best = votes.enumerated().max { left, right in
      left.element < right.element
    }!.offset
    let winner = Double(rankedVotes.first ?? 0)
    let runnerUp = Double(rankedVotes.dropFirst().first ?? 0)
    let pairCount = Double(max(1, classCount * (classCount - 1) / 2))
    let margin = max(0.0, winner - runnerUp) / pairCount
    return (best, classes[best], min(1.0, 0.5 + margin))
  }

  private func kernel(features: [Double], support: Int) -> Double {
    let start = support * featureCount
    var squaredDistance = 0.0
    for feature in 0..<featureCount {
      let difference = features[feature] - Double(supportVectors[start + feature])
      squaredDistance += difference * difference
    }
    return exp(-gamma * squaredDistance)
  }
}

final class DayawOfflineModels {
  private var base: DayawSVM?
  private var diacritic: DayawSVM?

  func warmUp() throws {
    if base == nil { base = try DayawSVM(resourceName: "model_base") }
    if diacritic == nil { diacritic = try DayawSVM(resourceName: "model_dia") }
  }

  func classify(features: [Double], diacriticFeatures: Bool) throws -> [String: Any] {
    try warmUp()
    let result = try (diacriticFeatures ? diacritic : base)!.predict(features: features)
    return ["classIndex": result.classIndex, "classValue": result.classValue]
  }

  func classifyDetailed(features: [Double], diacriticFeatures: Bool) throws -> (
    classIndex: Int,
    classValue: Int,
    confidence: Double
  ) {
    try warmUp()
    return try (diacriticFeatures ? diacritic : base)!.predictWithConfidence(features: features)
  }
}