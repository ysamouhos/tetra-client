package org.tetra.live

import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.ComponentName
import android.content.Context
import android.os.SystemClock
import android.view.View
import android.widget.RemoteViews

/** Home screen widget: server, group, who talks (or who spoke last), tap-to-talk. */
class StatusWidgetProvider : AppWidgetProvider() {
    override fun onUpdate(context: Context, manager: AppWidgetManager, ids: IntArray) {
        val views = views(context)
        for (id in ids) manager.updateAppWidget(id, views)
    }

    companion object {
        fun refresh(ctx: Context) {
            val manager = AppWidgetManager.getInstance(ctx) ?: return
            val ids = manager.getAppWidgetIds(ComponentName(ctx, StatusWidgetProvider::class.java))
            if (ids.isEmpty()) return
            val views = views(ctx)
            for (id in ids) manager.updateAppWidget(id, views)
        }

        private fun views(ctx: Context): RemoteViews {
            val s = LiveStatus.load(ctx)
            val v = RemoteViews(ctx.packageName, R.layout.tetra_live_widget)
            if (s == null) {
                v.setTextViewText(R.id.tetra_live_server, "TETRA Terminal")
                v.setTextViewText(R.id.tetra_live_group, "Not connected")
                v.setTextViewText(R.id.tetra_live_line, "")
                v.setViewVisibility(R.id.tetra_live_timer, View.GONE)
                v.setViewVisibility(R.id.tetra_live_ptt, View.GONE)
            } else {
                v.setTextViewText(R.id.tetra_live_server, if (s.online) s.server else "${s.server} · offline")
                v.setTextViewText(R.id.tetra_live_group, s.group)
                val since = s.talkerSince
                if (s.talker != null && since != null) {
                    v.setTextViewText(R.id.tetra_live_line, s.talker)
                    v.setViewVisibility(R.id.tetra_live_timer, View.VISIBLE)
                    // Chronometer base is elapsedRealtime-based.
                    val base = SystemClock.elapsedRealtime() - (System.currentTimeMillis() - since)
                    v.setChronometer(R.id.tetra_live_timer, base, null, true)
                } else {
                    v.setTextViewText(R.id.tetra_live_line, s.lastTalker?.let { "Last: $it" } ?: s.ownLine)
                    v.setViewVisibility(R.id.tetra_live_timer, View.GONE)
                }
                v.setViewVisibility(R.id.tetra_live_ptt, if (s.canTalk || s.transmitting) View.VISIBLE else View.GONE)
                v.setImageViewResource(R.id.tetra_live_ptt, if (s.transmitting) R.drawable.tetra_live_ptt_stop else R.drawable.tetra_live_ptt_talk)
                v.setOnClickPendingIntent(R.id.tetra_live_ptt, PttReceiver.pendingToggle(ctx, 2))
            }
            PttReceiver.pendingOpenApp(ctx)?.let { v.setOnClickPendingIntent(R.id.tetra_live_root, it) }
            return v
        }
    }
}
