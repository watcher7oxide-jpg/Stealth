package com.example.neural_companion

import android.app.Activity
import android.content.Intent
import android.net.Uri
import android.os.Bundle
import android.provider.OpenableColumns
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileOutputStream

class MainActivity: FlutterActivity() {
    private val CHANNEL = "com.example.neural_companion/file_picker"
    private val PICK_GGUF_REQUEST_CODE = 9912
    private var pendingResult: MethodChannel.Result? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        // Capture unhandled crashes to disk
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
            if (call.method == "pickGgufFile") {
                pendingResult = result
                val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
                    addCategory(Intent.CATEGORY_OPENABLE)
                    type = "*/*"
                }
                startActivityForResult(intent, PICK_GGUF_REQUEST_CODE)
            } else {
                result.notImplemented()
            }
        }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode == PICK_GGUF_REQUEST_CODE) {
            if (resultCode == Activity.RESULT_OK && data?.data != null) {
                val uri: Uri = data.data!!
                // Offload to background thread
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

    /**
     * Resolves direct POSIX storage paths or streams using an 8KB buffer.
     * Never allocates large byte arrays in heap memory.
     */
    private fun resolveOrStreamFile(uri: Uri): String {
        // 1. Direct path check if on primary shared storage
        val docId = uri.path ?: ""
        if (docId.contains("primary:")) {
            val relativePath = docId.substringAfter("primary:")
            val directFile = File("/storage/emulated/0/$relativePath")
            if (directFile.exists() && directFile.canRead()) {
                return directFile.absolutePath
            }
        }

        // 2. Query display name
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

        // 3. Stream copy with an 8KB buffer (max memory consumption: 8KB)
        val targetFile = File(filesDir, fileName)
        contentResolver.openInputStream(uri)?.use { input ->
            FileOutputStream(targetFile).use { output ->
                val buffer = ByteArray(8192)
                var bytesRead: Int
                while (input.read(buffer).also { bytesRead = it } != -1) {
                    output.write(buffer, 0, bytesRead)
                }
            }
        } ?: throw IllegalStateException("Failed to open input stream for $uri")

        return targetFile.absolutePath
    }
}
