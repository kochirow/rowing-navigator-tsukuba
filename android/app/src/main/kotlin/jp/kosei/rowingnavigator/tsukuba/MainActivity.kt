package jp.kosei.rowingnavigator.tsukuba

import android.Manifest
import android.content.pm.PackageManager
import android.media.AudioManager
import android.os.Build
import android.os.PowerManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val permissionChannel = "jp.kosei.rowingnavigator.tsukuba/permissions"
    private val audioDiagnosticsChannel = "jp.kosei.rowingnavigator.tsukuba/audio_diagnostics"
    private val deviceDiagnosticsChannel = "jp.kosei.rowingnavigator.tsukuba/device_diagnostics"
    private val notificationPermissionRequestCode = 7012
    private var pendingNotificationResult: MethodChannel.Result? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, audioDiagnosticsChannel)
            .setMethodCallHandler { call, result ->
                if (call.method != "snapshot") {
                    result.notImplemented()
                    return@setMethodCallHandler
                }
                val audioManager = getSystemService(AUDIO_SERVICE) as AudioManager
                val outputs = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                    audioManager.getDevices(AudioManager.GET_DEVICES_OUTPUTS).map {
                        mapOf("type" to it.type.toString())
                    }
                } else {
                    emptyList()
                }
                result.success(
                    mapOf(
                        "mode" to audioManager.mode.toString(),
                        "isMusicActive" to audioManager.isMusicActive,
                        "speakerphoneOn" to audioManager.isSpeakerphoneOn,
                        "wiredHeadsetOn" to if (Build.VERSION.SDK_INT < Build.VERSION_CODES.N) {
                            audioManager.isWiredHeadsetOn
                        } else {
                            null
                        },
                        "bluetoothA2dpOn" to audioManager.isBluetoothA2dpOn,
                        "outputs" to outputs,
                    ),
                )
            }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, deviceDiagnosticsChannel)
            .setMethodCallHandler { call, result ->
                if (call.method != "snapshot") {
                    result.notImplemented()
                    return@setMethodCallHandler
                }
                val powerManager = getSystemService(POWER_SERVICE) as PowerManager
                val thermalState = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                    when (powerManager.currentThermalStatus) {
                        PowerManager.THERMAL_STATUS_NONE -> "nominal"
                        PowerManager.THERMAL_STATUS_LIGHT -> "fair"
                        PowerManager.THERMAL_STATUS_MODERATE -> "moderate"
                        PowerManager.THERMAL_STATUS_SEVERE -> "serious"
                        PowerManager.THERMAL_STATUS_CRITICAL,
                        PowerManager.THERMAL_STATUS_EMERGENCY,
                        PowerManager.THERMAL_STATUS_SHUTDOWN -> "critical"
                        else -> "unknown"
                    }
                } else {
                    "unavailable"
                }
                result.success(
                    mapOf(
                        "deviceManufacturer" to Build.MANUFACTURER,
                        "deviceModel" to Build.MODEL,
                        "deviceModelIdentifier" to Build.DEVICE,
                        "systemName" to "Android",
                        "systemVersion" to Build.VERSION.RELEASE,
                        "sdkInt" to Build.VERSION.SDK_INT,
                        "thermalState" to thermalState,
                        "lowPowerModeEnabled" to powerManager.isPowerSaveMode,
                    ),
                )
            }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, permissionChannel)
            .setMethodCallHandler { call, result ->
                if (call.method != "requestNotificationPermission") {
                    result.notImplemented()
                    return@setMethodCallHandler
                }
                if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU ||
                    checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) ==
                    PackageManager.PERMISSION_GRANTED
                ) {
                    result.success(true)
                    return@setMethodCallHandler
                }
                if (pendingNotificationResult != null) {
                    result.error("request_in_progress", "Notification permission request is in progress", null)
                    return@setMethodCallHandler
                }
                pendingNotificationResult = result
                requestPermissions(
                    arrayOf(Manifest.permission.POST_NOTIFICATIONS),
                    notificationPermissionRequestCode,
                )
            }
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode != notificationPermissionRequestCode) return
        val granted = grantResults.isNotEmpty() &&
            grantResults[0] == PackageManager.PERMISSION_GRANTED
        pendingNotificationResult?.success(granted)
        pendingNotificationResult = null
    }
}
