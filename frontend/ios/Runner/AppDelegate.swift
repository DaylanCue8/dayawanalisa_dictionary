import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private let offlineModels = DayawOfflineModels()

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
