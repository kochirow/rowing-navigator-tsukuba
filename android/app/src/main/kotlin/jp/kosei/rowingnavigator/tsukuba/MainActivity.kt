package jp.kosei.rowingnavigator.tsukuba

import android.Manifest
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Intent
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
    private val observerNotificationChannel = "jp.kosei.rowingnavigator.tsukuba/observer_notifications"
    private val observerAlertChannelId = "observer_alerts"
    private val observerAlertNotificationId = 7020
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
        // 監視端末が背面にある間の通知(要件定義 11/03 R3)。音なし・バイブあり。
        // 艇ごとに tag を艇IDにして、同じ艇の通知を上書きする。
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, observerNotificationChannel)
            .setMethodCallHandler { call, result ->
                if (call.method != "show") {
                    result.notImplemented()
                    return@setMethodCallHandler
                }
                val id = call.argument<String>("id")
                val title = call.argument<String>("title")
                val body = call.argument<String>("body")
                if (id == null || title == null || body == null) {
                    result.error("bad_args", "id/title/body", null)
                    return@setMethodCallHandler
                }
                try {
                    showObserverAlert(id, title, body)
                    result.success(true)
                } catch (error: Exception) {
                    result.success(false)
                }
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

    private fun showObserverAlert(id: String, title: String, body: String) {
        val manager = getSystemService(NOTIFICATION_SERVICE) as NotificationManager
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O &&
            manager.getNotificationChannel(observerAlertChannelId) == null
        ) {
            val channel = NotificationChannel(
                observerAlertChannelId,
                "監視中の艇の知らせ",
                NotificationManager.IMPORTANCE_HIGH,
            ).apply {
                description = "監視端末が背面にある間の、漕手の警告・更新途絶・長時間停止"
                setSound(null, null)
                enableVibration(true)
                vibrationPattern = longArrayOf(0, 250, 150, 250)
            }
            manager.createNotificationChannel(channel)
        }
        val intent = Intent(this, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP
        }
        val pendingIntent = PendingIntent.getActivity(
            this,
            0,
            intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, observerAlertChannelId)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
                .setPriority(Notification.PRIORITY_HIGH)
                .setVibrate(longArrayOf(0, 250, 150, 250))
        }
        val notification = builder
            .setSmallIcon(applicationInfo.icon)
            .setContentTitle(title)
            .setContentText(body)
            .setCategory(Notification.CATEGORY_STATUS)
            .setAutoCancel(true)
            .setContentIntent(pendingIntent)
            .build()
        manager.notify(id, observerAlertNotificationId, notification)
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
