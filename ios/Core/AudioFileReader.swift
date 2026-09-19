import Foundation
import AVFoundation
import AudioToolbox

/**
 Decodes audio out of a `CachedByteSource` into PCM buffers a player node can
 schedule.

 `AVAudioFile` is deliberately not used, and the reason is the whole argument
 for this class existing. Its `length` is computed once when the file is opened
 and never re-derived, so a partial file reports a partial duration; and a read
 past the current end returns success with zero frames, indistinguishable from
 a real end-of-file, with no way to say "would block". Both were confirmed
 rather than assumed — see `spikes/ios-reader`.

 `AudioFileOpenWithCallbacks` has neither problem, because we answer the size
 question ourselves. The parser is told the resource's true length, the read
 proc is handed offsets rather than a cursor, and the source blocks until the
 bytes arrive.

 Takes any `ByteSource`, because there are two transports: a ranged direct
 stream, and a transcoded one that can only serve what has arrived. The reader
 does not care which — it asks for bytes and either gets them or waits.

 Not thread-safe: one reader per producer thread, which is the shape the design
 wants anyway.
 */
public final class AudioFileReader: TrackReader {

  public enum ReaderError: Error {
    case openFailed(OSStatus)
    case wrapFailed(OSStatus)
    case formatFailed(OSStatus)
    case readFailed(OSStatus)
  }

  private let source: ByteSource
  private var audioFile: AudioFileID?
  private var extFile: ExtAudioFileRef?

  /// Playable frames — the music, with the encoder's padding already taken off
  /// both ends. Seeking is expressed against this, not against the file.
  public private(set) var totalFrames: Int64 = 0

  /// Silence the encoder put at the front, which playback skips. Zero for
  /// formats that are sample-exact.
  public private(set) var primingFrames: Int64 = 0
  /// Silence at the end, which playback stops before.
  public private(set) var remainderFrames: Int64 = 0

  /**
   Whether `totalFrames` was counted or guessed.

   `kExtAudioFileProperty_FileLengthFrames` answers both questions with the
   same number and says nothing about which one it answered. Where the
   container carries a packet table — the MP4 family, and an MP3 with a
   Xing/LAME header — the count is real: every packet's frames are accounted
   for, and the length is the music to the sample. Where it does not, Core
   Audio has nothing to count and **extrapolates from the leading frames'
   bitrate**, which for a VBR file is a guess about the rest of the song made
   from its first few seconds.

   That guess goes short on exactly the files people stream. A front-loaded
   VBR MP3 — a loud opening, a quieter second half — spends more bits per
   second at the head than it averages, so multiplying the head's rate by the
   file's bytes under-counts the frames. `read` then stopped at a number that
   was never the end of anything, returned nil, and `TrackPlayback` read that
   as the file running out. The queue advanced. Same symptom as every other
   fault in §12 of `docs/architecture.md`, arriving through the one door left
   open: a length that looked like a fact.

   MP3 is where it was reported and MP3 is the one format that cannot be
   fixtured in process — Core Audio decodes it and will not encode it, which
   is the standing gap CONTRIBUTING names. So the distinction is drawn from
   the file rather than from the format: the packet table either answered or
   it did not, and nothing here has to know which container asked.
   */
  public private(set) var lengthIsMeasured = false

  /// Playable frames handed out so far. Tracked rather than asked for, because
  /// `ExtAudioFile` counts in file frames and this has to count in music.
  private var framesRead: Int64 = 0

  /**
   Why the read callback could not serve, when it was not the end of the file.

   `readProc` answers Core Audio with an `OSStatus` and cannot throw, and
   returning an error status is not enough on its own: the WAV parser passes it
   up, and the FLAC parser swallows it and reports `noErr` with zero frames —
   which `read` cannot tell from a file that ended. So the reason is recorded
   here on the way down and raised by `read` on the way back up.

   Set on the thread inside `ExtAudioFileRead`, which is the same thread that
   called it: `AudioFileReader` is explicitly not thread-safe, and
   `TrackPlayback.stopAndWait` exists to keep it that way.
   */
  fileprivate var sourceFailure: Error?

  /**
   Whether the decoder has to be put back before it can be read again.

   A failed read does not leave every parser where it found it. WAV carries on
   from the next call, because there is no decoder state to lose — but Core
   Audio's FLAC parser latches, and every subsequent read returns zero frames
   whatever the source does. Measured: a stall a quarter of the way into a
   five-second file left it stuck at 40,960 frames of 220,500, and it never
   moved again after the source recovered.

   That matters because `TrackPlayback` retries a failed read for about
   thirty-three seconds and retries *the same reader*. Against a latched parser
   the ladder cannot win — it either exhausts the budget or comes back with a
   clean end — so a hiccup the connection recovered from a second later still
   ended the track. Seeking back to the current position rebuilds the parser's
   state, and is cheap: the bytes it re-reads are the ones already in the cache.
   */
  private var needsResetAfterFailure = false

  /// The file-type hint `open` was given, so a rebuild can use it again.
  private var openHint: AudioFileTypeID = 0

  /**
   Whether the read callback unwound because a read was cancelled on purpose.

   `readProc` answers a cancellation with `kAudioFileEndOfFileError`, which is
   how a seek abandons the read in flight without looking like a corrupt track.
   That is enough for WAV and FLAC, whose parsers pass the ending up as zero
   frames. The MP4 parser does not: it treats the truncation as a hard error
   and `ExtAudioFileRead` returns a failure status, so a deliberate seek on an
   ALAC or AAC track surfaced as a decode error.

   So the intent is carried across the callback boundary, the same way a
   failure is, and `read` uses it to unwind cleanly whatever the status says.
   */
  fileprivate var sourceCancelled = false
  public private(set) var sampleRate: Double = 0
  public private(set) var channelCount: UInt32 = 0

  /// The format handed out — float32 non-interleaved, which is what an
  /// `AVAudioPlayerNode` wants and what the graph is wired for.
  public private(set) var outputFormat: AVAudioFormat?

  public init(source: ByteSource) {
    self.source = source
  }

  deinit {
    if let extFile { ExtAudioFileDispose(extFile) }
    if let audioFile { AudioFileClose(audioFile) }
  }

  /**
   Open the stream.

   `hint` is the file-type hint Core Audio gets. Worth passing when the
   container is known from the URL or the server's content type: without it the
   parser sniffs, which costs extra reads at the head — and reads are network
   requests here, not memcpy.
   */
  /// `TrackReader`'s spelling. A defaulted argument does not satisfy a
  /// protocol requirement in Swift, so the no-hint case is written out.
  public func open() throws { try open(hint: 0) }

  public func open(hint: AudioFileTypeID = 0) throws {
    // Kept so a rebuild after a failed read opens the same way this did,
    // rather than making the parser sniff a container it was told about once.
    openHint = hint
    let context = Unmanaged.passUnretained(self).toOpaque()

    var file: AudioFileID?
    let status = AudioFileOpenWithCallbacks(
      context,
      AudioFileReader.readProc,
      nil,
      AudioFileReader.sizeProc,
      nil,
      hint,
      &file
    )
    guard status == noErr, let file else { throw ReaderError.openFailed(status) }
    audioFile = file

    var ext: ExtAudioFileRef?
    let wrapped = ExtAudioFileWrapAudioFileID(file, false, &ext)
    guard wrapped == noErr, let ext else { throw ReaderError.wrapFailed(wrapped) }
    extFile = ext

    var native = AudioStreamBasicDescription()
    var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
    let gotFormat = ExtAudioFileGetProperty(ext, kExtAudioFileProperty_FileDataFormat, &size, &native)
    guard gotFormat == noErr else { throw ReaderError.formatFailed(gotFormat) }

    sampleRate = native.mSampleRate
    // Everything downstream is stereo; a mono source is widened by the
    // converter rather than special-cased in the graph.
    channelCount = max(1, min(2, native.mChannelsPerFrame))

    var client = AudioStreamBasicDescription(
      mSampleRate: native.mSampleRate,
      mFormatID: kAudioFormatLinearPCM,
      mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsNonInterleaved | kAudioFormatFlagIsPacked,
      mBytesPerPacket: 4,
      mFramesPerPacket: 1,
      mBytesPerFrame: 4,
      mChannelsPerFrame: 2,
      mBitsPerChannel: 32,
      mReserved: 0
    )
    let setClient = ExtAudioFileSetProperty(
      ext, kExtAudioFileProperty_ClientDataFormat,
      UInt32(MemoryLayout.size(ofValue: client)), &client)
    guard setClient == noErr else { throw ReaderError.formatFailed(setClient) }

    outputFormat = AVAudioFormat(
      commonFormat: .pcmFormatFloat32, sampleRate: native.mSampleRate,
      channels: 2, interleaved: false)

    var frames: Int64 = 0
    var frameSize = UInt32(MemoryLayout<Int64>.size)
    ExtAudioFileGetProperty(ext, kExtAudioFileProperty_FileLengthFrames, &frameSize, &frames)

    // Asked first, because its *answer* is what says whether the length below
    // may be treated as a boundary — see `lengthIsMeasured`.
    lengthIsMeasured = readEncoderPadding(from: file)
    // Used as reported. `ExtAudioFile` has already applied the packet table:
    // measured on a 2s AAC file, it returns 88200 for 88200 frames of input
    // with priming=2112 and remainder=824 sitting alongside — so this length
    // is the music, and subtracting the padding again would report every lossy
    // track ~3000 frames short.
    totalFrames = frames
  }

  /**
   Encoder delay and padding, read for the record rather than to act on.

   Lossy encoders cannot represent an arbitrary number of samples: MP3 and AAC
   work in fixed blocks, so they pad the start (priming, for the decoder to
   warm up) and the end (remainder, to fill the last block). Untrimmed, every
   track gains a few tens of milliseconds of silence at each end — inaudible
   alone, and exactly the seam that makes a live album or a DJ set sound
   broken. This is what "gapless" is about.

   **Core Audio already trims it, and this was measured rather than assumed.**
   `ExtAudioFile` applies the packet table itself: `FileLengthFrames` comes
   back as the playable length and the first read is music, not silence. The
   first version of this code subtracted the padding from the length and
   seeked past the priming — which reported every lossy track ~3000 frames
   short and skipped 2112 frames of real audio at the head of each one. The
   test alongside pins the platform behaviour so that stays visible.

   Kept exposed because "how much padding does this file declare" is worth
   being able to see, and because a future format handled by a decoder that
   does *not* trim would need it.

   Returns whether the packet table answered at all, which is a second and
   more load-bearing fact than the padding it hands back — see
   `lengthIsMeasured`. The two are the same question asked once: a container
   that can say how much padding it has is a container whose frames have been
   counted, and one that cannot is one whose length was extrapolated.
   */
  private func readEncoderPadding(from file: AudioFileID) -> Bool {
    var info = AudioFilePacketTableInfo()
    var size = UInt32(MemoryLayout<AudioFilePacketTableInfo>.size)
    let status = AudioFileGetProperty(file, kAudioFilePropertyPacketTableInfo, &size, &info)
    guard status == noErr else { return false }
    primingFrames = Int64(max(0, info.mPrimingFrames))
    remainderFrames = Int64(max(0, info.mRemainderFrames))
    return true
  }

  /**
   How many frames beyond `frame` are already fetched.

   An estimate, and deliberately a crude one: it maps frames to bytes by
   assuming a constant rate across the file. That is exact for PCM, close for
   CBR, and wrong in the middle of a VBR file — a quiet passage occupies fewer
   bytes than a loud one, so the figure drifts either way.

   Good enough because of what it is for. This drives a buffering indicator, a
   thing whose only job is to distinguish "stalled" from "fine". Being ten
   percent out on how much is buffered changes nothing anyone can see; being
   unable to say whether anything is buffered at all is the failure worth
   avoiding, and the alternative on offer was reporting zero forever.

   Never used for a decision — not for scheduling, not for the crossfade
   trigger, not for end-of-track. Only for display.
   */
  public func bufferedFramesAhead(ofFrame frame: Int64) -> Int64 {
    guard totalFrames > 0, let totalBytes = try? source.totalBytes(), totalBytes > 0 else {
      return 0
    }
    let bytesPerFrame = Double(totalBytes) / Double(totalFrames)
    guard bytesPerFrame > 0 else { return 0 }

    let byteOffset = Int64(Double(frame) * bytesPerFrame)
    let available = source.availableBytes(from: byteOffset)
    return Int64(Double(available) / bytesPerFrame)
  }

  /**
   Seek, in playable frames — which is what `ExtAudioFile` already counts in,
   padding excluded. No priming correction here: adding one skips real audio,
   which is what the first version of this did.

   The upper bound follows `read`'s, and for the same reason. A counted length
   is a real end and clamping to it is right. An extrapolated one is not a
   bound at all, and treating it as one is the truncation bug wearing a second
   set of clothes: the seek bar is drawn from `PlaybackEngine.trustedDuration`,
   which prefers the host's length when the two disagree materially — so a
   listener dragging to 2:50 of a song the parser guessed was 2:40 long landed
   at 2:40 and heard the track end. Silently, because a clamp reports nothing.

   Seeking past the real end of an extrapolated file is left to fail rather
   than be rounded down. `ExtAudioFileSeek` either refuses, which arrives as a
   thrown read failure the engine says out loud, or lands at the end, which
   arrives as a track that finished. Both are honest answers to a seek past
   the end; quietly playing somewhere else is not one.
   */
  public func seek(toFrame frame: Int64) throws {
    guard let extFile else { return }
    let clamped = lengthIsMeasured ? max(0, min(frame, totalFrames)) : max(0, frame)
    let status = ExtAudioFileSeek(extFile, clamped)
    guard status == noErr else { throw ReaderError.readFailed(status) }
    framesRead = clamped
  }

  /**
   Unblock a read parked on the network, so the producer thread unwinds.

   Forwarded to the byte source, which is the only thing that can be waiting.
   The read proc turns the resulting `cancelled` into end-of-file, so the
   parser unwinds cleanly and `read` returns nil — see `readProc`.

   Exposed here rather than reaching for the source directly because this class
   owns it, and because "stop waiting" is a reader-level idea: the caller
   holding a reader has no business knowing whether the bytes come from a
   socket or a file.
   */
  public var isSequential: Bool { source.isSequential }

  public func cancelPendingReads() { source.cancel() }

  /// Undo `cancelPendingReads`. Required before the reader is used again — a
  /// cancelled source refuses every read until it is put back to work.
  public func resumePendingReads() { source.resume() }

  /**
   Build a fresh parser over the same source, positioned where the decode was.

   A seek is not enough, and that was measured rather than assumed: after a
   failed read a seek back to the current frame yielded exactly one more buffer
   — 41,472 frames where the whole file is 220,500 — and then stopped again.
   The latch is in the `AudioFile` parser underneath, not in the `ExtAudioFile`
   cursor above it, so both are disposed and rebuilt.

   Cheap despite how it reads. The bytes the new parser needs to re-read are
   the ones the byte source already has: reopening costs a header parse against
   the cache, not a second download.

   `framesRead` is carried across deliberately — it is the position the *audio*
   has reached, which the new parser knows nothing about, and it is what the
   seek at the end restores.
   */
  private func rebuildAfterFailure() throws {
    let resumeAt = framesRead
    // Carried across for the same reason `framesRead` is. A fresh parser
    // re-reads the header and so comes back with the header's answer, which on
    // an extrapolated length is the under-count this reader has already
    // decoded past. Letting the rebuild reinstate it would re-arm the
    // truncation a stall had nothing to do with.
    let provenFrames = totalFrames

    if let extFile { ExtAudioFileDispose(extFile) }
    if let audioFile { AudioFileClose(audioFile) }
    extFile = nil
    audioFile = nil

    try open(hint: openHint)

    totalFrames = max(totalFrames, max(provenFrames, resumeAt))
    framesRead = resumeAt
    guard let ext = extFile else { throw ReaderError.openFailed(-1) }
    let status = ExtAudioFileSeek(ext, resumeAt)
    guard status == noErr else { throw ReaderError.readFailed(status) }
  }

  /**
   Decode up to `frames` frames.

   Returns nil at end of stream. A short buffer is normal near the end and is
   not an error.
   */
  public func read(frames: AVAudioFrameCount) throws -> AVAudioPCMBuffer? {
    // Cleared first so only what happened during *this* call is considered.
    sourceFailure = nil
    sourceCancelled = false

    // A previous read failed and may have left the parser unable to go on.
    // Rebuilt before anything is asked of it — and before `extFile` is read
    // below, because recovery replaces it.
    if needsResetAfterFailure {
      needsResetAfterFailure = false
      do {
        try rebuildAfterFailure()
      } catch {
        // Still down. Report it as the failure it is so the caller can retry,
        // and stay armed so the next attempt tries to recover again.
        needsResetAfterFailure = true
        throw error
      }
    }

    guard let extFile, let outputFormat else { return nil }

    // Stop at the last frame of music rather than the last frame of file. The
    // remainder is the encoder's block padding; decoding it would append
    // silence to every lossy track, which is the other half of the seam.
    //
    // **Only where that last frame was counted.** This is the whole of the
    // truncation fix and it is deliberately narrow, because the trailing
    // silence this guard exists to prevent is a real bug that was really
    // shipped — see `readEncoderPadding` and `GaplessTrimmingTests`, which
    // pins it. The two are not in tension once the question is asked
    // precisely: padding can only be trimmed off a length that accounts for
    // it, and a length that accounts for it is one the packet table produced.
    // A file with no packet table has no declared padding to leave behind and
    // an extrapolated length to stop at — so stopping there trims nothing and
    // discards music, which is the reported fault exactly.
    //
    // Where the length was extrapolated the end of the audio is therefore the
    // end of the *bytes*, and it is `readProc` that decides what that means.
    // That decision is already careful: an empty read is an ending only at a
    // length the source genuinely knows, and anything else is carried up as
    // the failure it is. Handing the question there rather than answering it
    // from a guess here is the point of the change.
    let remaining = lengthIsMeasured && totalFrames > 0 ? totalFrames - framesRead : Int64(frames)
    guard remaining > 0 else { return nil }
    let wanted = AVAudioFrameCount(min(Int64(frames), remaining))

    guard let buffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: wanted) else {
      return nil
    }

    // The buffer list advertises frameLength, not capacity, and
    // ExtAudioFileRead reads mDataByteSize to decide how much it may write.
    // Left at zero it returns paramErr — which looks exactly like an
    // unsupported format, and cost an hour during the spike.
    buffer.frameLength = wanted

    var count = wanted
    let status = ExtAudioFileRead(extFile, &count, buffer.mutableAudioBufferList)

    // Asked before the status and the frame count, because neither can be
    // trusted to carry it. Returning an error from `readProc` is not enough:
    // WAV propagates it, and FLAC does not — Core Audio's FLAC parser absorbs
    // the failed read and reports `noErr` with zero frames, which is
    // indistinguishable from the file ending. The engine believes it and
    // advances, and a listener hears the song skip itself part-way through.
    // Proven by test rather than assumed: the same stall throws on WAV and
    // ended cleanly on FLAC, which is the format the fault was reported in.
    if let failure = sourceFailure {
      sourceFailure = nil
      needsResetAfterFailure = true
      throw failure
    }

    // Before the status, for the same reason: a cancellation is deliberate and
    // ends the read, but the MP4 parser reports it as an error rather than as
    // an ending. Raising that would make an ordinary seek look like a broken
    // track — which is the exact confusion `readProc` answers EOF to avoid.
    if sourceCancelled {
      sourceCancelled = false
      return nil
    }

    guard status == noErr else { throw ReaderError.readFailed(status) }
    guard count > 0 else { return nil }

    framesRead += Int64(count)
    // An extrapolated length is a floor, not a ceiling, and the decoder is the
    // thing that can prove it wrong. Every frame handed out past it is a frame
    // the file demonstrably holds, so the figure is corrected rather than left
    // to go on being wrong for the rest of the track.
    //
    // Not cosmetic. `totalFrames` is what the seek bar, the buffered estimate
    // and `PlaybackEngine.referenceDuration` are all drawn from, and it is the
    // second opinion `endedShortOfItsLength` consults before deciding whether
    // an end was honest. A length that only ever under-reports would have that
    // check disbelieve every ending on a VBR file. A measured length cannot
    // reach here: the clamp above stops the read at it.
    if framesRead > totalFrames { totalFrames = framesRead }
    buffer.frameLength = count
    return buffer
  }

  // MARK: - Core Audio callbacks

  private static let readProc: AudioFile_ReadProc = { context, position, requestCount, buffer, actualCount in
    let reader = Unmanaged<AudioFileReader>.fromOpaque(context).takeUnretainedValue()
    do {
      let data = try reader.source.read(offset: position, count: Int(requestCount))
      if data.isEmpty {
        actualCount.pointee = 0
        // Empty *at or past* the end is the end. Empty before it is a source
        // that could not serve the bytes, which is a different thing entirely
        // and must not be reported as the song finishing.
        //
        // "The end" has to mean a length the source actually knows. A
        // sequential source answers `totalBytes()` with an *estimate* until
        // its producer reports finishing — so believing that estimate here
        // turns "we have not received these bytes yet" into "the track is
        // over", and the engine advances the queue on it. `isFinished` is
        // false until the producer's own onFinish fires, which is the only
        // thing that genuinely knows the stream ended; a ranged source
        // reports true, because its length came from Content-Length and was
        // never a guess.
        let total = (try? reader.source.totalBytes()) ?? 0
        let lengthIsKnown = reader.source.isFinished || !reader.source.isSequential
        if total > 0 && position >= total && lengthIsKnown {
          return kAudioFileEndOfFileError
        }
        reader.sourceFailure = ByteSourceError.fetchFailed(
          "empty read at \(position) of \(total)"
        )
        return kAudioFilePositionError
      }
      data.withUnsafeBytes { raw in
        buffer.copyMemory(from: raw.baseAddress!, byteCount: data.count)
      }
      actualCount.pointee = UInt32(data.count)
      return noErr
    } catch ByteSourceError.cancelled {
      actualCount.pointee = 0
      // Remembered as well as reported, because not every parser passes the
      // ending up as an ending. See `sourceCancelled`.
      reader.sourceCancelled = true
      // A cancelled read is not a corrupt file — a seek abandons the read in
      // flight on purpose. Reporting end-of-file lets the parser unwind
      // cleanly instead of surfacing a decode error the caller would have to
      // distinguish from a genuinely broken track.
      return kAudioFileEndOfFileError
    } catch {
      actualCount.pointee = 0
      // Carried out of the callback as well as reported through the status,
      // because a parser is free to absorb the status and Core Audio's FLAC
      // one does. See `sourceFailure`.
      reader.sourceFailure = error
      // Everything else is a failure to read, and reporting it as the end of
      // the file is what made a stalled network indistinguishable from a song
      // ending. The engine took the end-of-file at face value and advanced —
      // no error anywhere, nothing thrown, the track simply "finished" a
      // minute in. Every fix upstream of here was invisible to it, because the
      // failure had already been relabelled as success before it left this
      // callback.
      return kAudioFilePositionError
    }
  }

  private static let sizeProc: AudioFile_GetSizeProc = { context in
    let reader = Unmanaged<AudioFileReader>.fromOpaque(context).takeUnretainedValue()
    return (try? reader.source.totalBytes()) ?? 0
  }
}
