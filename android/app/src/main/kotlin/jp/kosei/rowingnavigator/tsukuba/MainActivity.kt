package jp.kosei.rowingnavigator.tsukuba

import android.Manifest
import android.content.pm.PackageManager
import android.media.AudioManager
import android.os.Build
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val permissionChannel = "jp.kosei.rowingnavigator.tsukuba/permissions"
    private val audioDiagnosticsChannel = "jp.kosei.rowingnavigator.tsukuba/audio_diagnostics"
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
