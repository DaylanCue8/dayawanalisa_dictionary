package com.example.dayaw

import android.os.Handler
import android.os.Looper
import com.chaquo.python.Python
import com.chaquo.python.android.AndroidPlatform
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.Executors

/**
 * Runs the Baybayin recognizer offline, inside the app, with Chaquopy
 * (Python on Android). Flutter talks to it over the "dayaw/offline_ocr"
 * channel:
 *   recognize(image: bytes, inputType: "pen"|"marker") -> JSON string
 *   translateText(text)                                 -> JSON string
 *   warmUp()                                            -> loads the models early
 * Python runs on a background thread so the screen never freezes.
 */
class MainActivity : FlutterActivity() {
    private val channelName = "dayaw/offline_ocr"
    private val worker = Executors.newSingleThreadExecutor()
    private val mainHandler = Handler(Looper.getMainLooper())

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        if (!Python.isStarted()) {
            Python.start(AndroidPlatform(applicationContext))
        }

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "recognize" -> {
                        val image = call.argument<ByteArray>("image")
                        val inputType = call.argument<String>("inputType") ?: "marker"
                        if (image == null) {
                            result.error("NO_IMAGE", "No image bytes were sent", null)
                        } else {
                            runPython(result) { module ->
                                module.callAttr("recognize", image, inputType).toString()
                            }
                        }
                    }
                    "translateText" -> {
                        val text = call.argument<String>("text") ?: ""
                        runPython(result) { module ->
                            module.callAttr("translate_text", text).toString()
                        }
                    }
                    "warmUp" -> runPython(result) { module ->
                        module.callAttr("warm_up").toString()
                    }
                    else -> result.notImplemented()
                }
            }
    }

    private fun runPython(
        result: MethodChannel.Result,
        block: (com.chaquo.python.PyObject) -> String,
    ) {
        worker.execute {
            try {
                val module = Python.getInstance().getModule("baybayin_offline")
                val output = block(module)
                mainHandler.post { result.success(output) }
            } catch (e: Exception) {
                mainHandler.post { result.error("PYTHON_ERROR", e.message, e.toString()) }
            }
        }
    }
}