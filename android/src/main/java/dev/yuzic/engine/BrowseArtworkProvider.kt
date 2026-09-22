package dev.yuzic.engine

import android.content.ContentProvider
import android.content.ContentResolver
import android.content.ContentValues
import android.content.Context
import android.content.Intent
import android.database.Cursor
import android.net.Uri
import android.os.ParcelFileDescriptor
import android.util.Log
import okhttp3.Request
import java.io.File
import java.io.FileNotFoundException
import java.security.MessageDigest

/**
 * Cover art for the car's browse rows, served from this app.
 *
 * Handing a car an `https` URL for a row's cover fails three ways. Media3 and
 * the car fetch it themselves, with no hook for a request header, so a server
 * behind Basic auth drew every row blank. Android Automotive does not load
 * remote artwork in browse lists at all. And a downloaded track's cover is a
 * `file://` path the car has no permission to read. Google's guidance for all
 * three is the same: give the car a `content://` URI and serve the bytes from a
 * provider, which is this.
 *
 * The URI names a node of the tree, not a URL, so nothing that reaches the car
 * carries a token, and the provider only ever serves what the current tree
 * points at. It is not exported: each car that browses is granted read access
 * to the rows it was shown (see [grantTo]).
 *
 * Remote covers are fetched once, with the node's headers and the same
 * certificate-aware client as audio, and kept in the cache directory, because
 * a car asks for the same fifty covers on every screen it draws.
 */
class BrowseArtworkProvider : ContentProvider() {

  override fun onCreate(): Boolean = true

  override fun openFile(uri: Uri, mode: String): ParcelFileDescriptor {
    if (mode != "r") throw SecurityException("car artwork is read-only")
    val context = context ?: throw FileNotFoundException("no context")
    val id = uri.pathSegments.takeIf { it.size == 2 && it[0] == NODE_PATH }?.get(1)
      ?: throw FileNotFoundException("not a browse node: $uri")
    val node = findBrowseNode(PlaybackService.browseRoot, id)
      ?: throw FileNotFoundException("no such node")
    val source = artworkSourceOf(node) ?: throw FileNotFoundException("no artwork")

    val file = when (Uri.parse(source).scheme?.lowercase()) {
      "file" -> File(Uri.parse(source).path ?: throw FileNotFoundException("bad path"))
      "http", "https" -> fetched(context, source, artworkHeadersOf(node))
      else -> throw FileNotFoundException("unsupported artwork")
    }
    if (!file.isFile) throw FileNotFoundException("artwork unavailable")
    return ParcelFileDescriptor.open(file, ParcelFileDescriptor.MODE_READ_ONLY)
  }

  /**
   * The cached copy of [url], fetched first if there is none.
   *
   * Blocking, which `openFile` is allowed to be: it runs on a binder thread
   * and the car shows a placeholder until it returns. Written to a staging
   * file and renamed, so a fetch that dies halfway never leaves a truncated
   * image to be served forever after.
   */
  private fun fetched(context: Context, url: String, headers: Map<String, String>): File {
    val dir = cacheDir(context).apply { mkdirs() }
    val target = File(dir, sha256(url))
    synchronized(lockFor(target.name)) {
      if (target.length() > 0) {
        target.setLastModified(System.currentTimeMillis())
        return target
      }
      // A cover that just failed is not asked for again on the next screen.
      val failedAt = misses[target.name]
      if (failedAt != null && System.currentTimeMillis() - failedAt < MISS_RETRY_MS) {
        throw FileNotFoundException("artwork recently unavailable")
      }
      val request = try {
        Request.Builder().url(url).apply { headers.forEach { (name, value) -> header(name, value) } }.build()
      } catch (_: IllegalArgumentException) {
        throw FileNotFoundException("bad artwork url")
      }
      val staged = File(dir, "${target.name}.tmp")
      try {
        PlaybackService.clientCertificateTransport.audioCallFactory.newCall(request).execute().use { response ->
          // An error page is a body too, and a car would try to draw it.
          if (!response.isSuccessful) throw FileNotFoundException("artwork answered ${response.code}")
          val body = response.body ?: throw FileNotFoundException("empty artwork")
          staged.outputStream().use { out -> body.byteStream().copyTo(out) }
        }
        if (staged.length() == 0L || !staged.renameTo(target)) throw FileNotFoundException("artwork not stored")
      } catch (error: java.io.IOException) {
        staged.delete()
        misses[target.name] = System.currentTimeMillis()
        // One line, not a stack trace: a library whose server has no covers
        // misses on every row of every screen, and the trace says nothing the
        // message does not.
        Log.w(TAG, "car artwork unavailable: ${error.message}")
        throw FileNotFoundException("artwork fetch failed")
      }
      trim(dir)
      return target
    }
  }

  override fun getType(uri: Uri): String? = null

  override fun query(
    uri: Uri,
    projection: Array<out String>?,
    selection: String?,
    selectionArgs: Array<out String>?,
    sortOrder: String?,
  ): Cursor? = null

  override fun insert(uri: Uri, values: ContentValues?): Uri? = null

  override fun delete(uri: Uri, selection: String?, selectionArgs: Array<out String>?): Int = 0

  override fun update(uri: Uri, values: ContentValues?, selection: String?, selectionArgs: Array<out String>?): Int = 0

  companion object {
    private const val TAG = "yuzic-engine"
    private const val NODE_PATH = "node"

    /** Enough for several screens of every tab, and small enough not to matter. */
    private const val MAX_FILES = 400

    /** How long a failed cover is left alone before it is tried again. */
    private const val MISS_RETRY_MS = 10 * 60 * 1000L

    /** When each cover last failed, by cache name. Memory only: a restart tries again. */
    private val misses = java.util.concurrent.ConcurrentHashMap<String, Long>()

    private val locks = java.util.concurrent.ConcurrentHashMap<String, Any>()
    private fun lockFor(name: String): Any = locks.getOrPut(name) { Any() }

    fun authority(context: Context) = "${context.packageName}.yuzicengine.artwork"

    private fun cacheDir(context: Context) = File(context.cacheDir, "yuzic-engine/car-artwork")

    /**
     * What a car should be given for [node]'s cover, or null when it has none.
     *
     * Remote and local covers go through this provider. Anything else, a
     * resource or another app's content URI, is already something the car can
     * open and is passed through.
     */
    internal fun carUriFor(context: Context, node: BrowseNodeRecord): Uri? {
      val source = artworkSourceOf(node) ?: return null
      val parsed = Uri.parse(source)
      if (parsed.scheme?.lowercase() !in PROVIDED_SCHEMES) return parsed
      return Uri.Builder()
        .scheme(ContentResolver.SCHEME_CONTENT)
        .authority(authority(context))
        .appendPath(NODE_PATH)
        .appendPath(node.id)
        // A different cover for the same row is a different URI, or a car
        // that caches by URI keeps drawing the old one.
        .appendQueryParameter("v", sha256(source).take(12))
        .build()
    }

    /** Let the car that is browsing open [uri]. Harmless to repeat. */
    internal fun grantTo(context: Context, packageName: String, uri: Uri) {
      if (uri.authority != authority(context)) return
      try {
        context.grantUriPermission(packageName, uri, Intent.FLAG_GRANT_READ_URI_PERMISSION)
      } catch (error: SecurityException) {
        Log.w(TAG, "could not grant car artwork to $packageName", error)
      }
    }

    /** The row's own cover, else the cover of the track it plays. */
    internal fun artworkSourceOf(node: BrowseNodeRecord): String? =
      node.artworkUri?.takeIf { it.isNotEmpty() } ?: node.playable?.artworkUri?.takeIf { it.isNotEmpty() }

    private fun artworkHeadersOf(node: BrowseNodeRecord): Map<String, String> =
      if (!node.artworkUri.isNullOrEmpty()) node.artworkHeaders.orEmpty()
      else node.playable?.artworkHeaders.orEmpty()

    /** Everything fetched, for a sign-out: covers are the library's too. */
    internal fun clear(context: Context) {
      misses.clear()
      cacheDir(context).deleteRecursively()
    }

    private val PROVIDED_SCHEMES = setOf("http", "https", "file")

    private fun trim(dir: File) {
      val files = dir.listFiles { file -> !file.name.endsWith(".tmp") } ?: return
      if (files.size <= MAX_FILES) return
      files.sortedBy { it.lastModified() }.take(files.size - MAX_FILES).forEach { it.delete() }
    }

    private fun sha256(text: String): String =
      MessageDigest.getInstance("SHA-256").digest(text.toByteArray()).joinToString("") { "%02x".format(it) }
  }
}
