package dev.yuzic.engine

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Log
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/**
 * One file, encrypted, that survives the process dying.
 *
 * Encrypted, because what the engine keeps is not just titles: every track
 * carries its stream URL and request headers, which is where a server's token
 * lives. The host keeps secrets in the platform keystore and nowhere else, so
 * this does the same: AES-GCM under a key that stays in the Android Keystore,
 * in `noBackupFilesDir` so a device backup does not carry it off. Anything that
 * fails to read back (a key the system invalidated, a file from a different
 * format) is deleted and treated as absent, because not knowing is the correct
 * answer to not being able to read.
 */
internal class SealedFile(private val file: File) {

  @Synchronized
  fun write(plain: ByteArray) {
    try {
      val cipher = Cipher.getInstance(TRANSFORMATION)
      cipher.init(Cipher.ENCRYPT_MODE, key())
      val sealed = cipher.doFinal(plain)
      val iv = cipher.iv
      val staged = File(file.path + ".tmp")
      staged.outputStream().use { out ->
        out.write(iv.size)
        out.write(iv)
        out.write(sealed)
      }
      // Renamed into place so a process killed mid-write leaves the previous
      // copy rather than half of this one.
      if (!staged.renameTo(file)) {
        file.delete()
        staged.renameTo(file)
      }
    } catch (error: Exception) {
      Log.w(TAG, "could not keep ${file.name}", error)
    }
  }

  @Synchronized
  fun read(): ByteArray? {
    if (!file.exists()) return null
    return try {
      val bytes = file.readBytes()
      val ivLength = bytes[0].toInt()
      val iv = bytes.copyOfRange(1, 1 + ivLength)
      val cipher = Cipher.getInstance(TRANSFORMATION)
      cipher.init(Cipher.DECRYPT_MODE, key(), GCMParameterSpec(TAG_BITS, iv))
      cipher.doFinal(bytes, 1 + ivLength, bytes.size - 1 - ivLength)
    } catch (error: Exception) {
      Log.w(TAG, "discarding ${file.name}, which could not be read back", error)
      file.delete()
      null
    }
  }

  @Synchronized
  fun delete() {
    file.delete()
    File(file.path + ".tmp").delete()
  }

  private fun key(): SecretKey {
    val keyStore = KeyStore.getInstance(KEYSTORE).apply { load(null) }
    (keyStore.getKey(KEY_ALIAS, null) as? SecretKey)?.let { return it }
    val generator = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, KEYSTORE)
    generator.init(
      KeyGenParameterSpec.Builder(
        KEY_ALIAS,
        KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT,
      )
        .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
        .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
        .setKeySize(256)
        .build()
    )
    return generator.generateKey()
  }

  companion object {
    private const val TAG = "yuzic-engine"
    private const val KEYSTORE = "AndroidKeyStore"
    // The browse tree's name, kept when the queue started sharing it: renaming
    // it would orphan the key every existing install already holds.
    private const val KEY_ALIAS = "dev.yuzic.engine.browse-tree"
    private const val TRANSFORMATION = "AES/GCM/NoPadding"
    private const val TAG_BITS = 128

    fun inNoBackup(context: Context, name: String) =
      SealedFile(File(context.applicationContext.noBackupFilesDir, name))
  }
}

/**
 * The last browse tree the host set, kept across the process dying.
 *
 * A car starts [PlaybackService] on its own: Android Auto when the phone
 * connects, Android Automotive when the driver opens the media app. Neither
 * starts the host's JavaScript, which only runs once the app's own screen has
 * opened, so a car arriving at a process that had died got the empty stand-in
 * root and nothing else. The common case, the phone in a pocket and the app
 * not opened today, was an empty library in the car every time. Keeping the
 * tree means the car gets the last library straight away, and a selection
 * plays from it without JavaScript, as it always has.
 */
internal class BrowseTreeStore(private val sealed: SealedFile) {

  fun save(title: String, nodes: List<FlatBrowseNodeRecord>) =
    sealed.write(BrowseTreeCodec.encode(title, nodes).toByteArray(Charsets.UTF_8))

  fun load(): Pair<String, List<FlatBrowseNodeRecord>>? {
    val plain = sealed.read() ?: return null
    return try {
      BrowseTreeCodec.decode(String(plain, Charsets.UTF_8))
    } catch (_: Exception) {
      null
    } ?: run { sealed.delete(); null }
  }

  fun clear() = sealed.delete()

  companion object {
    fun forContext(context: Context) = BrowseTreeStore(SealedFile.inNoBackup(context, "browse-tree.bin"))
  }
}

/**
 * The queue as it last stood, for a car or a headset that asks to carry on.
 *
 * Media3 calls `onPlaybackResumption` when something asks the session to play
 * with nothing loaded: Android Auto reconnecting, a Bluetooth play button, the
 * system's own resume card. With the process fresh there is no queue in memory
 * and no JavaScript to ask, so without this every one of those did nothing.
 * Kept in the same sealed form as the tree, and for the same reason: each track
 * carries a stream URL with a token in it.
 */
internal class ResumptionStore(private val sealed: SealedFile) {

  data class Saved(val tracks: List<TrackRecord>, val index: Int, val positionMs: Long)

  fun save(saved: Saved) =
    sealed.write(ResumptionCodec.encode(saved).toByteArray(Charsets.UTF_8))

  fun load(): Saved? {
    val plain = sealed.read() ?: return null
    return try {
      ResumptionCodec.decode(String(plain, Charsets.UTF_8))
    } catch (_: Exception) {
      null
    } ?: run { sealed.delete(); null }
  }

  fun clear() = sealed.delete()

  companion object {
    fun forContext(context: Context) = ResumptionStore(SealedFile.inNoBackup(context, "resume-queue.bin"))
  }
}

internal object ResumptionCodec {
  private const val VERSION = 1

  fun encode(saved: ResumptionStore.Saved): String =
    JSONObject()
      .put("v", VERSION)
      .put("index", saved.index)
      .put("positionMs", saved.positionMs)
      .put("tracks", JSONArray(saved.tracks.map(BrowseTreeCodec::encodeTrack)))
      .toString()

  /** Null for anything this version did not write, or a queue with nothing in it. */
  fun decode(json: String): ResumptionStore.Saved? {
    val root = JSONObject(json)
    if (root.optInt("v") != VERSION) return null
    val array = root.getJSONArray("tracks")
    val tracks = (0 until array.length()).map { BrowseTreeCodec.decodeTrack(array.getJSONObject(it)) }
    if (tracks.isEmpty()) return null
    return ResumptionStore.Saved(
      tracks,
      root.optInt("index").coerceIn(0, tracks.size - 1),
      root.optLong("positionMs").coerceAtLeast(0L),
    )
  }
}

/**
 * The tree as it arrives over the bridge, flat, in and out of JSON.
 *
 * Kept flat rather than as the assembled tree so that reading it back goes
 * through [buildBrowseTree] again, with the same duplicate, orphan and depth
 * rules as a tree fresh from the host. Pure, so it is tested on the JVM.
 */
internal object BrowseTreeCodec {
  /**
   * 2 added artwork headers, layout, icon and action. A version 1 file is still
   * read: it is the same shape without them, and throwing it away would leave
   * the car empty until the host next ran.
   */
  private const val VERSION = 2
  private val READABLE = setOf(1, VERSION)

  fun encode(title: String, nodes: List<FlatBrowseNodeRecord>): String =
    JSONObject()
      .put("v", VERSION)
      .put("title", title)
      .put("nodes", JSONArray(nodes.map(::encodeNode)))
      .toString()

  /** Null for anything this version cannot read. */
  fun decode(json: String): Pair<String, List<FlatBrowseNodeRecord>>? {
    val root = JSONObject(json)
    if (root.optInt("v") !in READABLE) return null
    val array = root.getJSONArray("nodes")
    val nodes = (0 until array.length()).map { decodeNode(array.getJSONObject(it)) }
    return root.getString("title") to nodes
  }

  private fun encodeNode(node: FlatBrowseNodeRecord) = JSONObject()
    .put("id", node.id)
    .putOpt("parentId", node.parentId)
    .put("title", node.title)
    .putOpt("subtitle", node.subtitle)
    .putOpt("artworkUri", node.artworkUri)
    .putOpt("artworkHeaders", node.artworkHeaders.takeIf { it.isNotEmpty() }?.let { JSONObject(it) })
    .putOpt("playable", node.playable?.let(::encodeTrack))
    .putOpt("layout", node.layout)
    .putOpt("icon", node.icon)
    .putOpt("action", node.action)

  private fun decodeNode(json: JSONObject) = FlatBrowseNodeRecord().apply {
    id = json.getString("id")
    parentId = json.optStringOrNull("parentId")
    title = json.getString("title")
    subtitle = json.optStringOrNull("subtitle")
    artworkUri = json.optStringOrNull("artworkUri")
    artworkHeaders = json.optJSONObject("artworkHeaders")?.toStringMap().orEmpty()
    playable = json.optJSONObject("playable")?.let(::decodeTrack)
    layout = json.optStringOrNull("layout")
    icon = json.optStringOrNull("icon")
    action = json.optStringOrNull("action")
  }

  fun encodeTrack(track: TrackRecord) = JSONObject()
    .put("id", track.id)
    .put("uri", track.uri)
    .put("title", track.title)
    .putOpt("artist", track.artist)
    .putOpt("album", track.album)
    .putOpt("artworkUri", track.artworkUri)
    .putOpt("artworkHeaders", track.artworkHeaders?.let { JSONObject(it) })
    .putOpt("durationSec", track.durationSec)
    .putOpt("headers", track.headers?.let { JSONObject(it) })
    .put("followsPrevious", track.followsPrevious)
    .putOpt("replayGainDb", track.replayGainDb)
    .putOpt("replayGainPeak", track.replayGainPeak)
    .put("continuous", track.continuous)

  fun decodeTrack(json: JSONObject) = TrackRecord().apply {
    id = json.getString("id")
    uri = json.getString("uri")
    title = json.getString("title")
    artist = json.optStringOrNull("artist")
    album = json.optStringOrNull("album")
    artworkUri = json.optStringOrNull("artworkUri")
    artworkHeaders = json.optJSONObject("artworkHeaders")?.toStringMap()
    durationSec = json.optDoubleOrNull("durationSec")
    headers = json.optJSONObject("headers")?.toStringMap()
    followsPrevious = json.optBoolean("followsPrevious")
    replayGainDb = json.optDoubleOrNull("replayGainDb")
    replayGainPeak = json.optDoubleOrNull("replayGainPeak")
    continuous = json.optBoolean("continuous")
  }

  private fun JSONObject.optStringOrNull(key: String): String? =
    if (has(key) && !isNull(key)) getString(key) else null

  private fun JSONObject.optDoubleOrNull(key: String): Double? =
    if (has(key) && !isNull(key)) getDouble(key) else null

  private fun JSONObject.toStringMap(): Map<String, String> =
    keys().asSequence().associateWith { getString(it) }
}
