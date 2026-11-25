package org.tetra.live

import android.content.Context
import org.json.JSONObject

/**
 * The radio status sent by the app (same keys as the iOS TetraStatus):
 * server, group, who talks and since when, own callsign and ISSI.
 * Times are milliseconds since the epoch.
 */
data class LiveStatus(
    val live: Boolean,
    val online: Boolean,
    val server: String,
    val group: String,
    val talker: String?,
    val talkerSince: Long?,
    val transmitting: Boolean,
    val emergency: Boolean,
    val ownName: String?,
    val ownIssi: Long?,
    val canTalk: Boolean,
    val txEndsAt: Long?,
    val lastTalker: String?,
) {
    /** "OE1XYZ · 2320001", or just one of them. */
    val ownLine: String
        get() = listOfNotNull(ownName?.takeIf { it.isNotBlank() }, ownIssi?.toString()).joinToString(" · ")

    val title: String get() = talker ?: server

    val text: String
        get() = when {
            talker != null && emergency -> "Emergency · $group"
            talker != null -> "$group · $server"
            !online -> "Reconnecting · " + listOf(ownLine, group).filter { it.isNotEmpty() }.joinToString(" · ")
            else -> "Standby · " + listOf(ownLine, group).filter { it.isNotEmpty() }.joinToString(" · ")
        }

    fun toJson(): String = JSONObject().apply {
        put("live", live); put("online", online); put("server", server); put("group", group)
        putOpt("talker", talker); putOpt("talkerSince", talkerSince); put("transmitting", transmitting)
        put("emergency", emergency); putOpt("ownName", ownName); putOpt("ownIssi", ownIssi)
        put("canTalk", canTalk); putOpt("txEndsAt", txEndsAt); putOpt("lastTalker", lastTalker)
    }.toString()

    companion object {
        private const val PREFS = "tetra_live"
        private const val KEY = "status"

        fun fromMap(m: Map<*, *>): LiveStatus = LiveStatus(
            live = m["live"] as? Boolean ?: false,
            online = m["online"] as? Boolean ?: false,
            server = m["server"] as? String ?: "",
            group = m["group"] as? String ?: "",
            talker = m["talker"] as? String,
            talkerSince = (m["talkerSince"] as? Number)?.toLong(),
            transmitting = m["transmitting"] as? Boolean ?: false,
            emergency = m["emergency"] as? Boolean ?: false,
            ownName = m["ownName"] as? String,
            ownIssi = (m["ownIssi"] as? Number)?.toLong(),
            canTalk = m["canTalk"] as? Boolean ?: false,
            txEndsAt = (m["txEndsAt"] as? Number)?.toLong(),
            lastTalker = m["lastTalker"] as? String,
        )

        private fun fromJson(s: String): LiveStatus {
            val j = JSONObject(s)
            fun str(k: String) = if (j.isNull(k)) null else j.optString(k)
            fun num(k: String) = if (j.isNull(k) || !j.has(k)) null else j.optLong(k)
            return LiveStatus(
                j.optBoolean("live"), j.optBoolean("online"), j.optString("server"), j.optString("group"),
                str("talker"), num("talkerSince"), j.optBoolean("transmitting"), j.optBoolean("emergency"),
                str("ownName"), num("ownIssi"), j.optBoolean("canTalk"), num("txEndsAt"), str("lastTalker"),
            )
        }

        fun save(ctx: Context, s: LiveStatus) {
            ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit().putString(KEY, s.toJson()).apply()
        }

        fun load(ctx: Context): LiveStatus? = try {
            ctx.getSharedPreferences(PREFS, Context.MODE_PRIVATE).getString(KEY, null)?.let(::fromJson)
        } catch (_: Exception) {
            null
        }
    }
}
