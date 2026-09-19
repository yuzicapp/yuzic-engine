import Foundation

/// Where bytes come from when the cache does not have them.
public protocol ByteFetcher: AnyObject {
  /// Total size of the resource. Asked once, and reported to the audio parser
  /// as the file's size even when almost none of it is on disk — see
  /// `CachedByteSource`.
  func contentLength() throws -> Int64
  /// Fetch exactly this range. Blocking; called off the render thread.
  func fetch(_ range: Range<Int64>) throws -> Data

  /**
   Abandon whatever `fetch` is waiting on, and refuse to start another until
   `resume`.

   The source above can only notice a cancel *between* fetches, so without this
   a seek arriving mid-request waits out the request — 30 seconds on a stalled
   connection, for something the listener expects to be instant. The bound has
   to come from the cancel.

   Defaulted to nothing because a fetcher that cannot block has nothing to
   abandon: reading a local file returns at disk speed, and the test fakes
   return immediately. Only the HTTP fetcher genuinely waits.
   */
  func cancel()
  func resume()
}

public extension ByteFetcher {
  func cancel() {}
  func resume() {}
}

public enum ByteSourceError: Error, Equatable {
  case cancelled
  case outOfBounds
  case fetchFailed(String)
}

/**
 A file with holes in it, that can answer a read at any offset.

 This is the thing the whole iOS design rests on. Core Audio's
 `AudioFile_ReadProc` hands us an *offset* rather than a cursor, and
 `AudioFile_GetSizeProc` is answered with the resource's true length even when
 nothing has been downloaded — so the parser believes it has a whole file, and
 a seek to the far end is an ordinary read rather than a special case. The spike
 in `spikes/ios-reader` confirmed that works: WAV and FLAC open and report the
 correct duration with only the first 30% present.

 Reads block. There is no async form of the read proc, so a miss means fetching
 the window and waiting. That is fine as long as it never happens on the render
 thread — a producer thread keeps PCM queued ahead, and a stall costs
 buffer-ahead rather than a dropout.

 **A miss is the thing to avoid, though, not merely to survive.** That last
 sentence was the whole plan for a long time and it was not enough: the PCM
 queued ahead is two seconds, a window is about two seconds of FLAC, and
 fetching was on demand — so a miss was due roughly every two seconds of
 playback and the slack behind it was exactly one miss deep. Read-ahead is the
 answer to that, and it is the third non-obvious behaviour below.

 Three behaviours here are not obvious and matter a great deal:

 - **Fetches are windowed and aligned**, not sized to the read. A parser asks
   for a few bytes at a time; issuing an HTTP request per read would be
   thousands of requests per track.
 - **MP4-family files get their tail fetched first.** `moov` sits at the end of
   a file that was not written faststart, and the spike showed the open failing
   outright without it — two of ALAC's first ten reads were past the fetched
   region. FLAC starts fine but cannot seek; M4A seeks fine but cannot start.
   Opposite failures, two mitigations.
 - **Fetching runs ahead of the decoder**, on its own queue, keeping
   `readAheadSeconds` of bytes in front of wherever the last read reached. See
   `readAheadSeconds` for why, and `runReadAhead` for the one piece of it that
   is genuinely delicate. This is the cushion; the PCM depth above it covers
   decode jitter and is not sized for a network.
 */
public final class CachedByteSource {

  public static let defaultWindowBytes: Int64 = 256 * 1024
  /// Enough for a `moov` atom on a typical album track.
  public static let tailPrefetchBytes: Int64 = 128 * 1024

  /**
   How far ahead of the decoder to keep fetching.

   This is the number the engine was missing. Fetching was purely on demand:
   `ensure` asked the network only for bytes a read had already arrived
   wanting, and `TrackPlayback` stops decoding once it is two seconds ahead —
   so nothing ever ran ahead of the decoder and the only cushion between the
   listener and the network was those two seconds of PCM. A 256KB window is
   about two seconds of FLAC, which means a round trip was due roughly every
   two seconds of playback with two seconds of slack to cover it. At the
   273ms measured against a real server that is fine. On a link having a bad
   minute it is a dropout, and it was: the same music, cutting out and coming
   back, on WiFi as well as cellular, with nothing failing anywhere.

   Thirty seconds is the target because it is the order Media3 uses on
   Android, where this fault was never reported — `DefaultLoadControl` holds
   tens of seconds and the same bad minute costs nothing. It is also well
   inside what the memory costs: `storage` is already allocated to the whole
   declared length of the file, so bytes fetched early occupy space that was
   reserved anyway. Read-ahead costs bandwidth and nothing else, and what it
   fetches is written through to `DiskCache` like any other window, so a
   track abandoned halfway keeps what it pulled.
   */
  public static let readAheadSeconds: Double = 30
  /// Floor and ceiling on the above, because it is derived from an estimated
  /// bitrate. The floor keeps a very low-bitrate stream from read-ahead so
  /// small it is not worth the name; the ceiling stops a 96/24 lossless track
  /// — around 3 Mbps, so eleven megabytes for thirty seconds — from pulling
  /// most of a file the listener may skip in five seconds.
  public static let minReadAheadBytes: Int64 = 512 * 1024
  public static let maxReadAheadBytes: Int64 = 8 * 1024 * 1024

  private let fetcher: ByteFetcher
  private let windowBytes: Int64
  private let lock = NSLock()

  private var storage: Data
  private var present = ByteRangeSet()
  private var cancelled = false
  private var length: Int64?

  /// Every range this source was asked for, in order. Diagnostic only — the
  /// spike used exactly this to discover that Apple's FLAC decoder reads from
  /// the start of the file to the seek point.
  public private(set) var requestLog: [Range<Int64>] = []

  /**
   Where fetched windows are also kept, and looked for first.

   Optional because most of this class's tests have no business touching a
   filesystem, and because the reader works without one — a nil cache is
   exactly the in-memory-only behaviour that existed before there was a disk.

   `cacheId` is the host's `MediaId` rather than the URL, for the reason
   `DiskCache` gives: stream URLs carry a rotating token.

   It is not the whole key, though, and this class supplies the other half
   without holding it: every call below passes `total` — the length this
   source's own fetcher declared — and `DiskCache` files the entry under the
   pair. That is deliberate rather than incidental. A source is built around
   one fetcher pointed at one URL and reads its length once, so `total` is
   fixed for the life of the source and cannot be the length of some other
   encoding; taking it straight from the same variable the read is being
   served against is what makes it impossible for this class to store bytes
   under a length they did not come from.
   */
  private let cache: DiskCache?
  private let cacheId: MediaId?

  /**
   The track's length in seconds, for turning `readAheadSeconds` into bytes.

   The conversion is `totalBytes / durationSec`, the same constant-bitrate
   estimate `AudioFileReader.bufferedFramesAhead` already makes — crude in the
   middle of a VBR file and close enough for deciding how much to fetch.

   **Nil turns read-ahead off**, rather than falling back to a byte figure.
   Without a duration there is nothing to say how much time a megabyte is
   worth, and the two ways of guessing are both bad: guess low on lossless and
   the read-ahead is not worth the name, guess high on a 96kbps podcast and a
   listener who skips after five seconds has paid for the whole episode. Every
   host yuzic talks to gives a duration, so this is the path nothing takes; a
   host that did not would fetch on demand exactly as the engine did before.
   */
  private let durationSec: Double?
  /// Read-ahead runs here, one window at a time, never on a decode thread.
  private let prefetchQueue = DispatchQueue(label: "dev.yuzic.engine.readahead", qos: .utility)
  /// Whether a read-ahead pass is running. Guarded by `lock`.
  private var prefetchScheduled = false
  /// Where the decoder has reached, which is where read-ahead works from.
  /// Guarded by `lock`; moved by every read, including one after a seek.
  private var prefetchFrom: Int64 = 0

  /**
   Held across a call to the fetcher, by whichever thread is fetching.

   `HTTPByteFetcher` keeps one `inFlight` task and cancels *it*, so two
   threads inside `fetch` at once would have the second overwrite the first's
   handle and a cancel reach the wrong request. Read-ahead therefore takes its
   turn rather than running alongside: a decode read can wait one window
   behind it, which is bounded and is usually the very window it wanted, and a
   seek cancels the request in flight whoever issued it.

   Never taken while `lock` is held — `lock` guards bookkeeping and is
   released before every fetch, which is the order this relies on.
   */
  private let fetchLock = NSLock()

  public init(
    fetcher: ByteFetcher,
    windowBytes: Int64 = CachedByteSource.defaultWindowBytes,
    cache: DiskCache? = nil,
    cacheId: MediaId? = nil,
    durationSec: Double? = nil
  ) {
    self.fetcher = fetcher
    self.windowBytes = max(4096, windowBytes)
    self.cache = cache
    self.cacheId = cacheId
    self.durationSec = durationSec
    self.storage = Data()
  }

  /// `readAheadSeconds` in bytes, from the declared length and the duration.
  /// Zero — no read-ahead — when there is no duration to convert with.
  private func readAheadBytes(total: Int64) -> Int64 {
    guard let durationSec, durationSec > 0, total > 0 else { return 0 }
    let perSecond = Double(total) / durationSec
    let wanted = Int64(perSecond * Self.readAheadSeconds)
    return min(Self.maxReadAheadBytes, max(Self.minReadAheadBytes, wanted))
  }

  /// Whether read-ahead runs at all, without needing the length to ask.
  private var readsAhead: Bool { (durationSec ?? 0) > 0 }

  /// The size the audio parser is told. The lie that makes the design work.
  public func totalBytes() throws -> Int64 {
    lock.lock()
    if let length { lock.unlock(); return length }
    lock.unlock()

    let fetched = try fetcher.contentLength()
    lock.lock()
    length = fetched
    if storage.count < Int(fetched) {
      storage.append(Data(count: Int(fetched) - storage.count))
    }
    lock.unlock()
    return fetched
  }

  /// Contiguous bytes available from `offset` — what a buffered-ahead readout
  /// is derived from.
  public func availableBytes(from offset: Int64) -> Int64 {
    lock.lock(); defer { lock.unlock() }
    return present.contiguousBytes(from: offset)
  }

  public func cancel() {
    lock.lock(); cancelled = true; lock.unlock()
    // Outside the lock: the fetcher is free to complete a request from another
    // thread as it tears down, and that completion wants this lock.
    fetcher.cancel()
  }

  public func resume() {
    lock.lock(); cancelled = false; lock.unlock()
    fetcher.resume()
  }

  /**
   Pull the end of the file in before anything else.

   Call for MP4-family containers. Cheap — one request — and without it an ALAC
   or AAC track will not open until the whole file has landed, because the
   parser's first reads are at the tail.
   */
  public func prefetchTail(bytes: Int64 = CachedByteSource.tailPrefetchBytes) throws {
    let total = try totalBytes()
    guard total > 0 else { return }
    let start = max(0, total - bytes)
    try ensure(start..<total)
  }

  /**
   The read behind `AudioFile_ReadProc`. Blocks until the bytes are present or
   the source is cancelled.

   Returns fewer bytes than asked for only at the true end of the resource,
   which is the one case Core Audio reads as end-of-file rather than an error.
   */
  public func read(offset: Int64, count: Int) throws -> Data {
    let total = try totalBytes()
    guard offset >= 0, offset < total else { return Data() }

    let end = min(offset + Int64(count), total)
    let wanted = offset..<end
    lock.lock(); requestLog.append(wanted); lock.unlock()

    try ensure(wanted)

    // Where the decoder has reached. Read-ahead works from the end of what was
    // just served rather than from the start, so a seek moves the mark in one
    // step instead of crawling forward behind the parser.
    scheduleReadAhead(from: end)

    lock.lock(); defer { lock.unlock() }
    return storage.subdata(in: Int(wanted.lowerBound)..<Int(wanted.upperBound))
  }

  // MARK: - Read-ahead

  /**
   Note where the decoder is and make sure a pass is running.

   Cheap and safe to call on every read, which is how it is called: a pass
   already running picks the new mark up on its next turn round the loop, so
   the thousands of small reads a parser makes produce one worker rather than
   thousands of queued closures.
   */
  private func scheduleReadAhead(from offset: Int64) {
    guard readsAhead else { return }
    lock.lock()
    prefetchFrom = offset
    if cancelled {
      // Nothing to start. The flag is left exactly as it was: a worker already
      // running will see `cancelled` and clear it on its way out, and clearing
      // it from here would let a second worker be dispatched alongside the
      // first.
      lock.unlock()
      return
    }
    let alreadyRunning = prefetchScheduled
    prefetchScheduled = true
    lock.unlock()

    guard !alreadyRunning else { return }
    prefetchQueue.async { [weak self] in self?.runReadAhead() }
  }

  /**
   Fetch forward from the mark until the window ahead is full.

   The exit is the fiddly part and is deliberately written to close a lost
   wakeup: the flag is cleared only while holding `lock`, having found both
   that there is no gap left *and* that nobody moved the mark while that was
   being decided. Clearing it on either fact alone loses a pass — the read
   that moved the mark saw `prefetchScheduled` still set and did not start
   one, and this worker went home without covering the new range.
   */
  private func runReadAhead() {
    while true {
      lock.lock()
      if cancelled {
        prefetchScheduled = false
        lock.unlock()
        return
      }
      let from = prefetchFrom
      lock.unlock()

      guard let total = try? totalBytes(), total > 0 else {
        lock.lock(); prefetchScheduled = false; lock.unlock()
        return
      }
      let target = min(total, from + readAheadBytes(total: total))

      lock.lock()
      let gap = from < target ? present.firstGap(from: from, limit: target) : nil
      if gap == nil, prefetchFrom == from {
        prefetchScheduled = false
        lock.unlock()
        return
      }
      lock.unlock()

      // The mark moved while that was being decided. Go round rather than
      // fetch against a position the decoder has left.
      guard let gap else { continue }

      do {
        // `atLeastTo` is the gap's *lower* bound, which is what makes this one
        // window rather than the whole gap: read-ahead has nobody waiting on
        // it, so it stays interruptible.
        try fetchWindow(from: gap.lowerBound, atLeastTo: gap.lowerBound, total: total)
      } catch {
        // Read-ahead is best effort by definition — the bytes it wanted are
        // not wanted *yet*. A failure here must not surface: the read that
        // eventually needs them goes through `ensure`, which has the retry
        // ladder above it and a listener waiting on the answer.
        lock.lock(); prefetchScheduled = false; lock.unlock()
        return
      }
    }
  }

  /// Fetch whatever part of `range` is missing, a window at a time.
  private func ensure(_ range: Range<Int64>) throws {
    let total = try totalBytes()

    while true {
      lock.lock()
      if cancelled { lock.unlock(); throw ByteSourceError.cancelled }
      let gap = present.firstGap(from: range.lowerBound, limit: min(range.upperBound, total))
      lock.unlock()

      guard let gap else { return }

      // A read serves the whole gap it was asked for, so the window may be
      // widened to cover it. Read-ahead takes one window at a time instead —
      // see `fetchWindow`.
      try fetchWindow(from: gap.lowerBound, atLeastTo: gap.upperBound, total: total)
    }
  }

  /**
   Fetch one window, or as much more as `atLeastTo` demands, and file it.

   Shared by the foreground read and read-ahead, which is why the extent is a
   parameter: a read has a gap it must cover before it can answer, while
   read-ahead passes its own lower bound and so always takes exactly one
   window. One window at a time is what keeps read-ahead interruptible — a
   seek lands between iterations rather than waiting out a multi-megabyte
   request nobody wants any more.
   */
  private func fetchWindow(from start: Int64, atLeastTo minimumEnd: Int64, total: Int64) throws {
    // Round out to a window so a parser reading a few bytes at a time does
    // not turn into a request per read.
    let windowStart = (start / windowBytes) * windowBytes
    let windowEnd = min(total, max(minimumEnd, windowStart + windowBytes))
    let toFetch = windowStart..<windowEnd

    // One fetch at a time, whoever is asking — see `fetchLock`.
    fetchLock.lock()
    defer { fetchLock.unlock() }

    // Re-checked now the turn has come round: the other thread may have been
    // fetching this very window while this one waited, and issuing the same
    // request twice is the obvious way for read-ahead to double a listener's
    // data usage.
    lock.lock()
    if cancelled { lock.unlock(); throw ByteSourceError.cancelled }
    let stillMissing = present.firstGap(from: toFetch.lowerBound, limit: toFetch.upperBound) != nil
    lock.unlock()
    guard stillMissing else { return }

    // Disk before network. A window already on disk costs a seek and a read
    // rather than a request, which is the entire point of the cache — and it
    // is checked per window rather than per track so a half-fetched track
    // resumes from wherever it got to.
    //
    // Asked for by length as well as by id, because "disk before network" was
    // true of the wrong disk for a while: the same id is a lossless file on
    // WiFi and a transcode on cellular, and a window cached from one was being
    // spliced into a decode of the other. The cache answers nil to a length it
    // was not filled at, which turns that into a miss and a request. See
    // `DiskCache.CacheKey`.
    let data: Data
    if let cache, let cacheId, let onDisk = cache.read(cacheId, range: toFetch, totalBytes: total) {
      data = onDisk
    } else {
      do {
        data = try fetcher.fetch(toFetch)
      } catch let error as ByteSourceError {
        throw error
      } catch {
        throw ByteSourceError.fetchFailed(String(describing: error))
      }
      // Written through immediately rather than at end of track: a track
      // abandoned halfway is exactly the one worth having kept, and there is
      // no "end" for the listener who skipped.
      if let cache, let cacheId, !data.isEmpty {
        cache.write(cacheId, offset: toFetch.lowerBound, data: data, totalBytes: total)
      }
    }

    lock.lock()
    if cancelled { lock.unlock(); throw ByteSourceError.cancelled }
    let landed = Int64(data.count)
    if landed > 0 {
      let upper = min(toFetch.lowerBound + landed, total)
      storage.replaceSubrange(Int(toFetch.lowerBound)..<Int(upper), with: data.prefix(Int(upper - toFetch.lowerBound)))
      present.insert(toFetch.lowerBound..<upper)
    }
    lock.unlock()

    // A fetch that returns nothing would otherwise spin forever.
    if landed == 0 { throw ByteSourceError.fetchFailed("empty response for \(toFetch)") }
  }
}
