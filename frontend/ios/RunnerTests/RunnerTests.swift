import Flutter
import UIKit
import XCTest

class RunnerTests: XCTestCase {

  func testInvalidImageReturnsFlutterRecognitionContract() throws {
    let recognizer = DayawImageRecognizer(models: DayawOfflineModels())
    let response = try recognizer.recognize(
      imageData: Data([0x00, 0x01, 0x02]), inputType: "pen"
    )

    XCTAssertEqual(response["status"] as? String, "Invalid_Image")
    XCTAssertEqual(response["translated_text"] as? String, "")
    XCTAssertEqual(response["individual_detections"] as? [[String: Any]], [])
    XCTAssertEqual(response["input_type_used"] as? String, "pen")
    XCTAssertEqual(response["offline"] as? Bool, true)
  }

  func testExample() {
    // If you add code to the Runner application, consider adding tests here.
    // See https://developer.apple.com/documentation/xctest for more information about using XCTest.
  }

}
