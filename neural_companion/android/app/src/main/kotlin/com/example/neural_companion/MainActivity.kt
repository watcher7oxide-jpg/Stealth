package com.example.neural_companion

import android.app.Activity
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.media.AudioManager
import android.media.ToneGenerator
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.IBinder
import android.os.PowerManager
import android.provider.OpenableColumns
import android.view.WindowManager
import androidx.core.app.NotificationCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileOutputStream

class CallService : Service() {
    private var wakeLock: PowerManager.WakeLock? = null

    override fun onCreate() {
        super.onCreate()
        val powerManager = getSystemService(Context.POWER_SERVICE) as PowerManager
        wakeLock = powerManager.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "NeuralCompanion:CallServiceLock")
        wakeLock?.acquire(60 * 60 * 1000L)
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val channelId = "neural_companion_call"
        val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                channelId,
                "Active Companion Call",
                NotificationManager.IMPORTANCE_LOW
            )
            manager.createNotificationChannel(channel)
        }

        val notification: Notification = NotificationCompat.Builder(this, channelId)
            .setContentTitle("Neural Companion Active")
            .setContentText("Continuous call mode connected...")
            .setSmallIcon(android.R.drawable.stat_notify_chat)
            .setOngoing(true)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .build()

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(1001, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE)
        } else {
            startForeground(1001, notification)
        }

        return START_STICKY
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onDestroy() {
        if (wakeLock?.isHeld == true) {
            wakeLock?.release()
        }
        stopForeground(true)
        super.onDestroy()
    }
}

class MainActivity: FlutterActivity() {
    private val CHANNEL = "com.example.neural_companion/file_picker"
    private val PICK_GGUF_REQUEST_CODE = 9912
    private var pendingResult: MethodChannel.Result? = null
    private var toneGenerator: ToneGenerator? = null
    private var audioManager: AudioManager? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        audioManager = getSystemService(Context.AUDIO_SERVICE) as AudioManager

        val defaultHandler = Thread.getDefaultUncaughtExceptionHandler()
        Thread.setDefaultUncaughtExceptionHandler { thread, throwable ->
            try {
                val crashFile = File(filesDir, "last_native_crash.txt")
                crashFile.writeText(
                    "Thread: ${thread.name}\n" +
                    "Exception: ${throwable.javaClass.name}\n" +
                    "Message: ${throwable.message}\n\n" +
                    "Stack Trace:\n" + throwable.stackTraceToString()
                )
            } catch (e: Exception) {
                e.printStackTrace()
            }
            defaultHandler?.uncaughtException(thread, throwable)
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "pickGgufFile" -> {
                    pendingResult = result
                    val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
                        addCategory(Intent.CATEGORY_OPENABLE)
                        type = "*/*"
                    }
                    startActivityForResult(intent, PICK_GGUF_REQUEST_CODE)
                }
                "setCallModeHardware" -> {
                    val enable = call.argument<Boolean>("enable") ?: false
                    setCallModeHardware(enable)
                    result.success(true)
                }
                "playTone" -> {
                    val type = call.argument<String>("type") ?: "processing"
                    playTone(type)
                    result.success(true)
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun setCallModeHardware(enable: Boolean) {
        runOnUiThread {
            if (enable) {
                // 1. Keep window active to prevent Google STT shutdown
                window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)

                // 2. Hardware Acoustic Echo Cancellation (AEC)
                audioManager?.mode = AudioManager.MODE_IN_COMMUNICATION
                audioManager?.isSpeakerphoneOn = true

                // 3. Start Foreground Service
                val serviceIntent = Intent(this, CallService::class.java)
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    startForegroundService(serviceIntent)
                } else {
                    startService(serviceIntent)
                }
            } else {
                window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                audioManager?.mode = AudioManager.MODE_NORMAL
                val serviceIntent = Intent(this, CallService::class.java)
                stopService(serviceIntent)
            }
        }
    }

    private fun playTone(type: String) {
        try {
            if (toneGenerator == null) {
                toneGenerator = ToneGenerator(AudioManager.STREAM_VOICE_CALL, 90)
            }
            when (type) {
                "processing" -> toneGenerator?.startTone(ToneGenerator.TONE_PROP_BEEP2, 100)
                "wake" -> toneGenerator?.startTone(ToneGenerator.TONE_PROP_ACK, 180)
                "stop" -> toneGenerator?.startTone(ToneGenerator.TONE_PROP_NACK, 150)
            }
        } catch (e: Exception) {
            e.printStackTrace()
        }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode == PICK_GGUF_REQUEST_CODE) {
            if (resultCode == Activity.RESULT_OK && data?.data != null) {
                val uri: Uri = data.data!!
                Thread {
                    try {
                        val path = resolveOrStreamFile(uri)
                        runOnUiThread {
                            pendingResult?.success(path)
                            pendingResult = null
                        }
                    } catch (e: Exception) {
                        runOnUiThread {
                            pendingResult?.error("FILE_ERROR", e.message, null)
                            pendingResult = null
                        }
                    }
                }.start()
            } else {
                pendingResult?.success(null)
                pendingResult = null
            }
        }
    }

    private fun resolveOrStreamFile(uri: Uri): String {
        val docId = uri.path ?: ""
        if (docId.contains("primary:")) {
            val relativePath = docId.substringAfter("primary:")
            val directFile = File("/storage/emulated/0/$relativePath")
            if (directFile.exists() && directFile.canRead()) {
                return directFile.absolutePath
            }
        }

        var fileName = "model.gguf"
        contentResolver.query(uri, null, null, null, null)?.use { cursor ->
            if (cursor.moveToFirst()) {
                val nameIndex = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                if (nameIndex != -1) {
                    val name = cursor.getString(nameIndex)
                    if (!name.isNullOrBlank()) {
                        fileName = name
                    }
                }
            }
        }

        val targetFile = File(filesDir, fileName)
        contentResolver.openInputStream(uri)?.use { input ->
            FileOutputStream(targetFile).use { output ->
                val buffer = ByteArray(8192)
                var bytesRead: Int
                while (input.read(buffer).also { bytesRead = it } != -1) {
                    output.write(buffer, 0, bytesRead)
                }
            }
        } ?: throw IllegalStateException("Failed to open stream for $uri")

        return targetFile.absolutePath
    }

    override fun onDestroy() {
        setCallModeHardware(false)
        toneGenerator?.release()
        toneGenerator = null
        super.onDestroy()
    }
}
