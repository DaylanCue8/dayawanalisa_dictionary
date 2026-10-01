import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private let offlineModels = DayawOfflineModels()
  private lazy var imageRecognizer = DayawImageRecognizer(models: offlineModels)

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)

    let channel = FlutterMethodChannel(
      name: "dayaw/offline_ocr",
      binaryMessenger: engineBridge.applicationRegistrar.messenger()
    )
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self else {
        result(nil)
        return
      }
      switch call.method {
      case "recognize":
        guard let arguments = call.arguments as? [String: Any],
              let rawImage = arguments["image"] else {
          result(FlutterError(code: "NO_IMAGE", message: "No image bytes were sent", details: nil))
          return
        }
        let imageData: Data?
        if let typedData = rawImage as? FlutterStandardTypedData {
          imageData = typedData.data
        } else if let data = rawImage as? Data {
          imageData = data
        } else if let bytes = rawImage as? [UInt8] {
          imageData = Data(bytes)
        } else {
          imageData = nil
        }
        guard let imageData else {
          result(FlutterError(code: "INVALID_IMAGE", message: "Expected image bytes", details: nil))
          return
        }
        let inputType = arguments["inputType"] as? String ?? "marker"
        DispatchQueue.global(qos: .userInitiated).async {
          do {
            let output = try self.imageRecognizer.recognize(
              imageData: imageData, inputType: inputType
            )
            let json = try JSONSerialization.data(withJSONObject: output)
            DispatchQueue.main.async {
              result(String(data: json, encoding: .utf8))
            }
          } catch {
            DispatchQueue.main.async {
              result(FlutterError(code: "MODEL_ERROR", message: error.localizedDescription, details: nil))
            }
          }
        }
      case "warmUp":
        DispatchQueue.global(qos: .userInitiated).async {
          do {
            try self.offlineModels.warmUp()
            DispatchQueue.main.async { result("ok") }
          } catch {
            DispatchQueue.main.async { result(FlutterError(code: "MODEL_ERROR", message: error.localizedDescription, details: nil)) }
          }
        }
      case "classifyFeatures":
        guard
          let arguments = call.arguments as? [String: Any],
          let rawFeatures = arguments["features"] as? [NSNumber]
        else {
          result(FlutterError(code: "INVALID_FEATURES", message: "Expected a features array", details: nil))
          return
        }
        let features = rawFeatures.map(\.doubleValue)
        let isDiacritic = arguments["diacritic"] as? Bool ?? false
        DispatchQueue.global(qos: .userInitiated).async {
          do {
            let output = try self.offlineModels.classify(
              features: features,
              diacriticFeatures: isDiacritic
            )
            DispatchQueue.main.async { result(output) }
          } catch {
            DispatchQueue.main.async { result(FlutterError(code: "MODEL_ERROR", message: error.localizedDescription, details: nil)) }
          }
        }
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }
}
