import Foundation
import AVFoundation
// Separate modules under SwiftPM, which is what lets `swift test` reach the
// decoder. In the pod everything is one module and these headers arrive
// through the umbrella, so the imports would not resolve and are not needed.
#if canImport(CVorbis)
import COgg
import CVorbis
#endif

/**
 An Ogg Vorbis decoder, because iOS does not have one.

 Core Audio decodes MP3, AAC, ALAC, FLAC, WAV and AIFF. It has no Vorbis
 decoder at all, so `AudioFileReader` cannot even open an `.ogg` — the failure
 is total rather than a quality loss, and a self-hosted library stored as
 Vorbis is simply unplayable. The app worked around it by asking the server to
 transcode, which costs the quality the person chose Original to keep.

 Xiph's `vorbisfile` does the work. It wants a stream it can read and seek, and
 `ByteSource` already is one, so the four callbacks below are the whole
 adaptation — no temporary files, and the same cache and range machinery the
 Core Audio path uses.

 Output is float32, non-interleaved, at the file's own rate: `vorbisfile` hands
 back planar float already, which is exactly what `AVAudioPCMBuffer` wants, so
 nothing is converted or copied twice.
 */
public final class VorbisFileReader: TrackReader {

  public enum VorbisError: Error {
    /// Not an Ogg Vorbis stream, or the header is damaged.
    case notVorbis(Int32)
    case seekFailed(Int32)
    case readFailed(Int32)
  }

  private let source: ByteSource
  private var file = OggVorbis_File()
  private var opened = false

  /// Where `vorbisfile` believes it is in the byte stream. It drives the reads
  /// itself, so this is the callbacks' cursor rather than a playback position.
  private var byteOffset: Int64 = 0

  /**
   Why the stream callback stopped serving bytes, when it was not the end.

   `readBytes` is a C callback and cannot throw: vorbisfile reads 0 as end of
   stream, exactly as `fread` does, and there is no other way out of it. So a
   failure is recorded here and raised by `read` on the way back up.

   See `OpusFileReader.sourceFailure` — the same fault, and the same one
   `AudioFileReader.readProc` carried before it: a stalled network read is
   indistinguishable from a finished file unless something carries the
   difference across the callback boundary.

   Touched only from the decode queue, like `byteOffset`.
   */
  private var sourceFailure: Error?

  /**
   Whether the callback returned 0 because a read was cancelled on purpose.

   `OpusFileReader` and `AudioFileReader` both carry this; this one did not,
   and relied on vorbisfile reading the 0 as a clean end of stream. That works
   — but "works" here means a cancellation arrives at `TrackPlayback` as
   `reachedEnd`, i.e. as the track finishing, and the only thing standing
   between that and a wrong advance is `stop()` happening to set `stopped`
   first. That is an invariant nothing states, holding up the exact confusion
   this file has been fixed for twice. Carried explicitly instead.
   */
  private var sourceCancelled = false

  public private(set) var totalFrames: Int64 = 0
  public private(set) var sampleRate: Double = 0
  public private(set) var channelCount: UInt32 = 0
  public private(set) var outputFormat: AVAudioFormat?

  public init(source: ByteSource) {
    self.source = source
  }

  deinit {
    if opened { ov_clear(&file) }
  }

  /**
   Read the headers and learn the shape of the stream.

   Idempotent, like the Core Audio reader: the factory opens a reader before
   handing it over and the engine opens it again.
   */
  public func open() throws {
    guard !opened else { return }

    let callbacks = ov_callbacks(
      read_func: { buffer, size, count, handle in
        let reader = Unmanaged<VorbisFileReader>.fromOpaque(handle!).takeUnretainedValue()
        return reader.readBytes(into: buffer, size: size, count: count)
      },
      seek_func: { handle, offset, whence in
        let reader = Unmanaged<VorbisFileReader>.fromOpaque(handle!).takeUnretainedValue()
        return reader.seekBytes(to: offset, whence: whence)
      },
      // Nothing to close: the `ByteSource` outlives this and is owned by
      // whoever built it.
      close_func: nil,
      tell_func: { handle in
        let reader = Unmanaged<VorbisFileReader>.fromOpaque(handle!).takeUnretainedValue()
        return Int(reader.byteOffset)
      }
    )

    let handle = Unmanaged.passUnretained(self).toOpaque()
    let status = ov_open_callbacks(handle, &file, nil, 0, callbacks)
    guard status == 0 else { throw VorbisError.notVorbis(status) }
    opened = true

    guard let info = ov_info(&file, -1) else { throw VorbisError.notVorbis(0) }
    sampleRate = Double(info.pointee.rate)
    channelCount = UInt32(info.pointee.channels)
    // `ov_pcm_total` is exact for a seekable stream and -1 for a live one,
    // which the engine already reads as "no finish line, draw no progress bar".
    let total = ov_pcm_total(&file, -1)
    totalFrames = total > 0 ? Int64(total) : 0

    outputFormat = AVAudioFormat(
      commonFormat: .pcmFormatFloat32,
      sampleRate: sampleRate,
      channels: AVAudioChannelCount(channelCount),
      interleaved: false
    )
  }

  public func seek(toFrame frame: Int64) throws {
    guard opened else { return }
    let status = ov_pcm_seek(&file, ogg_int64_t(max(0, frame)))
    guard status == 0 else { throw VorbisError.seekFailed(status) }
  }

  /**
   Decode up to `frames` frames.

   `ov_read_float` returns one packet at a time and will happily return fewer
   frames than asked for; that is normal and not end-of-stream, so this loops
   until the buffer is full or the stream genuinely ends. Returning short
   buffers instead would work but would multiply the scheduling traffic on the
   player node for no gain.
   */
  public func read(frames: AVAudioFrameCount) throws -> AVAudioPCMBuffer? {
    guard opened, let format = outputFormat,
          let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames),
          let channels = buffer.floatChannelData else { return nil }

    var filled: AVAudioFrameCount = 0
    while filled < frames {
      var pcm: UnsafeMutablePointer<UnsafeMutablePointer<Float>?>?
      let wanted = Int32(min(frames - filled, 4096))
      let decoded = ov_read_float(&file, &pcm, wanted, nil)

      // Asked before `decoded` is interpreted: a source that could not serve
      // makes vorbisfile report a clean end of stream, so 0 here means "the
      // file ended" only once this is nil.
      if let failure = sourceFailure {
        sourceFailure = nil
        throw failure
      }

      // Before `decoded` is judged: a cancelled read reaches vorbisfile as a 0
      // and comes back as a clean end of stream, which is the right unwind and
      // the wrong thing to report as a finished track.
      if sourceCancelled {
        sourceCancelled = false
        break
      }

      if decoded == 0 { break }                      // end of stream
      if decoded < 0 { throw VorbisError.readFailed(Int32(decoded)) }
      guard let pcm else { break }

      for channel in 0..<Int(channelCount) {
        if let plane = pcm[channel] {
          channels[channel].advanced(by: Int(filled))
            .update(from: plane, count: Int(decoded))
        }
      }
      filled += AVAudioFrameCount(decoded)
    }

    buffer.frameLength = filled
    return filled > 0 ? buffer : nil
  }

  /**
   How much beyond `frame` is already fetched, in frames.

   Converted from bytes by the stream's average bitrate, because Vorbis is
   variable-rate and there is no exact byte-to-frame map without seeking. It
   feeds a progress bar, and being a little out is invisible there; being
   expensive would not be.
   */
  public func bufferedFramesAhead(ofFrame frame: Int64) -> Int64 {
    guard opened, sampleRate > 0, totalFrames > 0 else { return 0 }
    let totalBytes = (try? source.totalBytes()) ?? 0
    guard totalBytes > 0 else { return 0 }
    let bytesAhead = source.availableBytes(from: byteOffset)
    let framesPerByte = Double(totalFrames) / Double(totalBytes)
    return Int64(Double(bytesAhead) * framesPerByte)
  }

  public var isSequential: Bool { source.isSequential }

  public func cancelPendingReads() { source.cancel() }
  public func resumePendingReads() { source.resume() }

  // MARK: - vorbisfile's stream, over a ByteSource

  private func readBytes(
    into buffer: UnsafeMutableRawPointer?,
    size: Int,
    count: Int
  ) -> Int {
    guard let buffer, size > 0, count > 0 else { return 0 }
    let wanted = size * count

    let data: Data
    do {
      data = try source.read(offset: byteOffset, count: wanted)
    } catch ByteSourceError.cancelled {
      // Abandoned on purpose by a seek: an ending, not a failure — but an
      // ending this reader states rather than infers.
      sourceCancelled = true
      return 0
    } catch {
      sourceFailure = error
      return 0
    }

    if data.isEmpty {
      // Empty *at or past* the end is the end. Empty before it is a source
      // that could not serve, which must not read as the song finishing.
      let total = (try? source.totalBytes()) ?? 0
      if !(total > 0 && byteOffset >= total) {
        sourceFailure = ByteSourceError.fetchFailed(
          "empty read at \(byteOffset) of \(total)"
        )
      }
      return 0
    }

    data.copyBytes(to: buffer.assumingMemoryBound(to: UInt8.self), count: data.count)
    byteOffset += Int64(data.count)
    // Returns whole *items*, as fread does — vorbisfile calls it with size 1,
    // and returning a byte count for a larger item size would overrun.
    return data.count / size
  }

  private func seekBytes(to offset: ogg_int64_t, whence: Int32) -> Int32 {
    let total = (try? source.totalBytes()) ?? 0
    let target: Int64
    switch whence {
    case SEEK_SET: target = Int64(offset)
    case SEEK_CUR: target = byteOffset + Int64(offset)
    case SEEK_END: target = total + Int64(offset)
    default: return -1
    }
    guard target >= 0 else { return -1 }
    byteOffset = target
    return 0
  }
}
