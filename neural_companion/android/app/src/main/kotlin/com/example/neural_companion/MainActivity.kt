package com.example.neural_companion

import android.os.Bundle
import io.flutter.embedding.android.FlutterActivity
import java.io.File

class MainActivity: FlutterActivity() {
        override fun onCreate(savedInstanceState: Bundle?) {
                    super.onCreate(savedInstanceState)

                            // Intercepts native/Java crashes and writes them to disk before exit
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
}
                                                                                            )
                                                        }}
        }
}