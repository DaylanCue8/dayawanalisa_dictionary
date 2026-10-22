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
 * Runs both recognizers offline, inside the app, with Chaquopy
 * (Python on Android). Flutter talks to them over the "dayaw/offline_ocr"
 * channel:
 *   recognize(image: bytes, inputType: "pen"|"marker") -> JSON string   (Baybayin -> Latin)
 *   recognizeLatin(image: bytes)                        -> JSON string   (Latin -> Baybayin)
 *   translateText(text)                                 -> JSON string   (OLD typed mode, to be removed)
 *   warmUp()                                            -> loads the models early
 * Python runs on a background thread so the screen never freezes.
 */
class MainActivity : FlutterActivity() {
    private val channelName = "dayaw/offline_ocr"
    private val worker = Executors.newSingleThreadExecutor()
    private val mainHandler = Handler(Looper.getMainLooper())

    // Python modules in android/app/src/main/python/
    private val baybayinModule = "baybayin_offline"     // Baybayin -> Latin
    private val latinModule = "latin_to_baybayin"       // Latin -> Baybayin

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
                            runPython(result, baybayinModule) { module ->
                                module.callAttr("recognize", image, inputType).toString()
                            }
                        }
                    }
                    "recognizeLatin" -> {
                        val image = call.argument<ByteArray>("image")
                        if (image == null) {
                            result.error("NO_IMAGE", "No image bytes were sent", null)
                        } else {
                            runPython(result, latinModule) { module ->
                                module.callAttr("recognize_latin_json", image).toString()
                            }
                        }
                    }
                    "translateText" -> {
                        val text = call.argument<String>("text") ?: ""
                        runPython(result, baybayinModule) { module ->
                            module.callAttr("translate_text", text).toString()
                        }
                    }
                    "warmUp" -> runPython(result, baybayinModule) { module ->
                        val status = module.callAttr("warm_up").toString()
                        // Latin model too. Its own try, so a missing/broken
                        // Latin model can never stop the Baybayin side.
                        try {
                            Python.getInstance().getModule(latinModule)
                                .callAttr("warm_up_latin")
                        } catch (e: Exception) {
                            android.util.Log.w("DAYAW", "Latin warm-up failed: ${e.message}")
                        }
                        status
                    }
                    else -> result.notImplemented()
                }
            }
    }

    private fun runPython(
        result: MethodChannel.Result,
        moduleName: String,
        block: (com.chaquo.python.PyObject) -> String,
    ) {
        worker.execute {
            try {
                val module = Python.getInstance().getModule(moduleName)
                val output = block(module)
                mainHandler.post { result.success(output) }
            } catch (e: Exception) {
                mainHandler.post { result.error("PYTHON_ERROR", e.message, e.toString()) }
            }
        }
    }
}