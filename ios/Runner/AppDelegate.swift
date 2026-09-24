import UIKit
import Flutter
import GoogleMaps
import AVFoundation
import Darwin

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    // Google Maps API key is injected from the untracked Secrets.xcconfig.
    // Keep release credentials out of Swift source and Git history.
    if let apiKey = Env.googleMapApiKey {
      GMSServices.provideAPIKey(apiKey)
    } else {
      preconditionFailure(
        "GOOGLE_MAPS_API_KEY is not configured. Set ios/Flutter/Secrets.xcconfig before distribution."
      )
    }

    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    let messenger = engineBridge.applicationRegistrar.messenger()

    do {
      let audioChannel = FlutterMethodChannel(
        name: "jp.kosei.rowingnavigator.tsukuba/audio_diagnostics",
        binaryMessenger: messenger
      )
      audioChannel.setMethodCallHandler { call, result in
        guard call.method == "snapshot" else {
          result(FlutterMethodNotImplemented)
          return
        }
        let session = AVAudioSession.sharedInstance()
        result([
          "category": session.category.rawValue,
          "mode": session.mode.rawValue,
          "categoryOptions": session.categoryOptions.rawValue,
          "inputs": session.currentRoute.inputs.map { [
            "type": $0.portType.rawValue,
          ] },
          "outputs": session.currentRoute.outputs.map { [
            "type": $0.portType.rawValue,
          ] },
          "outputVolume": session.outputVolume,
          "isOtherAudioPlaying": session.isOtherAudioPlaying,
          "secondaryAudioShouldBeSilencedHint": session.secondaryAudioShouldBeSilencedHint,
          "sampleRate": session.sampleRate,
          "ioBufferDurationMs": session.ioBufferDuration * 1000,
        ])
      }

      let deviceDiagnosticsChannel = FlutterMethodChannel(
        name: "jp.kosei.rowingnavigator.tsukuba/device_diagnostics",
        binaryMessenger: messenger
      )
      deviceDiagnosticsChannel.setMethodCallHandler { call, result in
        guard call.method == "snapshot" else {
          result(FlutterMethodNotImplemented)
          return
        }
        let processInfo = ProcessInfo.processInfo
        let thermalState: String
        switch processInfo.thermalState {
        case .nominal:
          thermalState = "nominal"
        case .fair:
          thermalState = "fair"
        case .serious:
          thermalState = "serious"
        case .critical:
          thermalState = "critical"
        @unknown default:
          thermalState = "unknown"
        }
        result([
          "deviceModel": UIDevice.current.model,
          "deviceModelIdentifier": self.machineIdentifier(),
          "systemName": UIDevice.current.systemName,
          "systemVersion": UIDevice.current.systemVersion,
          "thermalState": thermalState,
          "lowPowerModeEnabled": processInfo.isLowPowerModeEnabled,
        ])
      }
    }
  }

  private func machineIdentifier() -> String {
    var systemInfo = utsname()
    uname(&systemInfo)
    return withUnsafePointer(to: &systemInfo.machine) {
      $0.withMemoryRebound(to: CChar.self, capacity: 1) {
        String(cString: $0)
      }
    }
  }
}
