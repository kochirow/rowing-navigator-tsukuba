import UIKit
import Flutter
import GoogleMaps
import AVFoundation
import Darwin
import MetricKit
import UserNotifications

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

    // 背面での終了件数(MetricKit)は1日ごとに届く。起動直後から受け取れるよう
    // ここで購読する。失敗しても起動は止めない。
    MetricKitBackgroundExitStore.shared.start()

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

      // 監視端末が背面にある間の通知(要件定義 11/03 R3)。音は鳴らさない
      // (DESIGN_PRINCIPLES 3.5-3)。艇ごとに1つのIDで上書きする。
      let observerNotificationChannel = FlutterMethodChannel(
        name: "jp.kosei.rowingnavigator.tsukuba/observer_notifications",
        binaryMessenger: messenger
      )
      observerNotificationChannel.setMethodCallHandler { call, result in
        let center = UNUserNotificationCenter.current()
        switch call.method {
        case "requestPermission":
          // 音の許可は求めない。バナーと通知センターだけ。
          center.requestAuthorization(options: [.alert]) { granted, _ in
            DispatchQueue.main.async { result(granted) }
          }
        case "show":
          guard let args = call.arguments as? [String: Any],
            let id = args["id"] as? String,
            let title = args["title"] as? String,
            let body = args["body"] as? String
          else {
            result(FlutterError(code: "bad_args", message: "id/title/body", details: nil))
            return
          }
          let content = UNMutableNotificationContent()
          content.title = title
          content.body = body
          content.sound = nil
          content.threadIdentifier = "observer"
          // Time Sensitive の権限(entitlement)が無い間は、通常の通知として届く。
          content.interruptionLevel = .timeSensitive
          let request = UNNotificationRequest(
            identifier: "observer-\(id)", content: content, trigger: nil)
          center.add(request) { error in
            DispatchQueue.main.async { result(error == nil) }
          }
        default:
          result(FlutterMethodNotImplemented)
        }
      }

      let deviceDiagnosticsChannel = FlutterMethodChannel(
        name: "jp.kosei.rowingnavigator.tsukuba/device_diagnostics",
        binaryMessenger: messenger
      )
      deviceDiagnosticsChannel.setMethodCallHandler { call, result in
        if call.method == "backgroundExits" {
          result(MetricKitBackgroundExitStore.shared.storedPayloads())
          return
        }
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
          // アプリを作った SDK("iphoneos27.0" など)。位置取得の用途指定
          // maritime は iOS 27 の SDK で作ったときだけ効く(R7)。
          "buildSdkName": Bundle.main.object(forInfoDictionaryKey: "DTSDKName") as? String
            ?? "unknown",
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

/// MetricKit が1日ごとに届ける「背面での終了」の件数を端末内に保つ(R8-R3)。
///
/// 件数は期間(おおむね1日)ごとの累計で、どの練習で何が起きたかまでは分からない。
/// 診断ログでは「途切れた記録の手がかりの1つ」としてだけ使う。
final class MetricKitBackgroundExitStore: NSObject, MXMetricManagerSubscriber {
  static let shared = MetricKitBackgroundExitStore()

  private let storageKey = "metrickit_background_exits_v1"
  private let maxStoredPayloads = 14
  private let queue = DispatchQueue(label: "jp.kosei.rowingnavigator.metrickit")
  private var started = false

  func start() {
    queue.sync {
      guard !started else { return }
      started = true
      MXMetricManager.shared.add(self)
    }
  }

  func storedPayloads() -> [[String: Any]] {
    queue.sync { load() }
  }

  func didReceive(_ payloads: [MXMetricPayload]) {
    let formatter = ISO8601DateFormatter()
    let entries: [[String: Any]] = payloads.compactMap { payload in
      guard let exits = payload.applicationExitMetrics?.backgroundExitData else {
        return nil
      }
      return [
        "periodStart": formatter.string(from: payload.timeStampBegin),
        "periodEnd": formatter.string(from: payload.timeStampEnd),
        "normal": exits.cumulativeNormalAppExitCount,
        "memoryResourceLimit": exits.cumulativeMemoryResourceLimitExitCount,
        "memoryPressure": exits.cumulativeMemoryPressureExitCount,
        "cpuResourceLimit": exits.cumulativeCPUResourceLimitExitCount,
        "appWatchdog": exits.cumulativeAppWatchdogExitCount,
        "suspendedWithLockedFile": exits.cumulativeSuspendedWithLockedFileExitCount,
        "badAccess": exits.cumulativeBadAccessExitCount,
        "illegalInstruction": exits.cumulativeIllegalInstructionExitCount,
        "abnormal": exits.cumulativeAbnormalExitCount,
        "backgroundTaskAssertionTimeout":
          exits.cumulativeBackgroundTaskAssertionTimeoutExitCount,
      ]
    }
    guard !entries.isEmpty else { return }
    queue.async {
      var stored = self.load()
      stored.append(contentsOf: entries)
      if stored.count > self.maxStoredPayloads {
        stored.removeFirst(stored.count - self.maxStoredPayloads)
      }
      if let data = try? JSONSerialization.data(withJSONObject: stored) {
        UserDefaults.standard.set(data, forKey: self.storageKey)
      }
    }
  }

  private func load() -> [[String: Any]] {
    guard let data = UserDefaults.standard.data(forKey: storageKey),
      let decoded = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
    else {
      return []
    }
    return decoded
  }
}
