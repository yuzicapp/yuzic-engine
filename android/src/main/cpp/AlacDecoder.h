#pragma once
#include <cstddef>
#include <cstdint>

struct AVCodecContext;
struct AVFrame;
struct AVPacket;

namespace yuzic {
// One context per Media3 decoder/voice. No shared mutable codec state.
class AlacDecoder {
 public:
  explicit AlacDecoder(const uint8_t *cookie, size_t size);
  ~AlacDecoder();
  AlacDecoder(const AlacDecoder &) = delete;
  AlacDecoder &operator=(const AlacDecoder &) = delete;
  size_t decode(const uint8_t *packet, size_t size, uint8_t *pcm, size_t capacity);
  void flush();
  uint32_t channels() const { return channels_; }
  uint32_t sampleRate() const { return sampleRate_; }
  size_t maxOutputBytes() const { return size_t(frameLength_) * channels_ * 2; }
 private:
  AVCodecContext *context_ = nullptr;
  AVFrame *frame_ = nullptr;
  AVPacket *packet_ = nullptr;
  uint32_t channels_, sampleRate_, frameLength_;
};
}
