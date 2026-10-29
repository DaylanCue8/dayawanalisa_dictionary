package com.example.dayaw

import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.VibrationEffect
import android.os.Vibrator
import android.os.VibratorManager
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
 *   recognizeLatin(image: bytes, inputType: "pen"|"marker") -> JSON string (Latin -> Baybayin)
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
                        val inputType = call.argument<String>("inputType") ?: "pen"
                        if (image == null) {
                            result.error("NO_IMAGE", "No image bytes were sent", null)
                        } else {
                            runPython(result, latinModule) { module ->
                                module.callAttr("recognize_latin_json", image, inputType).toString()
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

        // Haptics straight from the vibrator: Flutter's HapticFeedback goes
        // through the system "touch feedback" setting, which many phones
        // turn off or ignore, so taps felt like nothing.
        //   vibrate(kind: "selection"|"light"|"heavy")
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "dayaw/haptics")
            .setMethodCallHandler { call, result ->
                if (call.method == "vibrate") {
                    vibrate(call.argument<String>("kind") ?: "light")
                    result.success(null)
                } else {
                    result.notImplemented()
                }
            }
    }

    private fun vibrate(kind: String) {
        val vibrator: Vibrator? =
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                (getSystemService(VIBRATOR_MANAGER_SERVICE) as? VibratorManager)
                    ?.defaultVibrator
            } else {
                @Suppress("DEPRECATION")
                getSystemService(VIBRATOR_SERVICE) as? Vibrator
            }
        if (vibrator == null || !vibrator.hasVibrator()) return
        when {
            Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q -> {
                val effect = when (kind) {
                    "selection" -> VibrationEffect.EFFECT_TICK
                    "heavy" -> VibrationEffect.EFFECT_HEAVY_CLICK
                    else -> VibrationEffect.EFFECT_CLICK
                }
                vibrator.vibrate(VibrationEffect.createPredefined(effect))
            }
            Build.VERSION.SDK_INT >= Build.VERSION_CODES.O -> {
                val (ms, amplitude) = when (kind) {
                    "selection" -> 12L to 90
                    "heavy" -> 40L to 255
                    else -> 20L to 160
                }
                vibrator.vibrate(VibrationEffect.createOneShot(ms, amplitude))
            }
            else -> {
                @Suppress("DEPRECATION")
                vibrator.vibrate(if (kind == "heavy") 40L else 15L)
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