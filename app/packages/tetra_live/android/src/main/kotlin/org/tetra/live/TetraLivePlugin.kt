package org.tetra.live

import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.util.Log
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * Channel "tetra/live" (as on iOS): the app sends the radio status, this
 * shows it in an ongoing notification (an Android 16 Live Update where
 * available) with a tap-to-talk button, and in the home screen widget.
 * Button taps come back to the app as "togglePtt".
 */
class TetraLivePlugin : FlutterPlugin, MethodChannel.MethodCallHandler {
    private lateinit var context: Context

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        val ch = MethodChannel(binding.binaryMessenger, "tetra/live")
        ch.setMethodCallHandler(this)
        channel = ch
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel?.setMethodCallHandler(null)
        channel = null
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "update" -> {
                val status = LiveStatus.fromMap(call.arguments as? Map<*, *> ?: emptyMap<String, Any>())
                LiveStatus.save(context, status)
                StatusWidgetProvider.refresh(context)
                if (status.live) LiveService.show(context) else LiveService.stop(context)
                result.success(null)
            }
            "end" -> {
                LiveService.stop(context)
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    companion object {
        private const val TAG = "TetraLive"
        private val main = Handler(Looper.getMainLooper())
        @Volatile var channel: MethodChannel? = null

        /** A PTT button was tapped: tell the app, or open it if it is not running. */
        fun togglePtt(ctx: Context) {
            main.post {
                val ch = channel
                if (ch != null) {
                    ch.invokeMethod("togglePtt", null)
                } else {
                    Log.i(TAG, "app not running, opening it")
                    ctx.packageManager.getLaunchIntentForPackage(ctx.packageName)?.let {
                        it.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                        try { ctx.startActivity(it) } catch (_: Exception) {}
                    }
                }
            }
        }

        val promotedSupported: Boolean get() = Build.VERSION.SDK_INT >= 36
    }
}
