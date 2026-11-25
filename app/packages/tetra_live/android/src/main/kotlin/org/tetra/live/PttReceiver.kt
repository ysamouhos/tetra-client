package org.tetra.live

import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

/** Tap-to-talk from the notification and the widget. */
class PttReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action == ACTION_TOGGLE) TetraLivePlugin.togglePtt(context)
    }

    companion object {
        const val ACTION_TOGGLE = "org.tetra.live.TOGGLE_PTT"

        fun pendingToggle(ctx: Context, requestCode: Int): PendingIntent = PendingIntent.getBroadcast(
            ctx, requestCode,
            Intent(ctx, PttReceiver::class.java).setAction(ACTION_TOGGLE),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )

        fun pendingOpenApp(ctx: Context): PendingIntent? =
            ctx.packageManager.getLaunchIntentForPackage(ctx.packageName)?.let {
                it.flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP
                PendingIntent.getActivity(ctx, 0, it, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
            }
    }
}
