#include "AlacDecoder.h"
extern "C" {
#include <libavcodec/avcodec.h>
#include <libavutil/error.h>
#include <libavutil/mem.h>
#include <libavutil/samplefmt.h>
}
#include <cstring>
#include <stdexcept>
#include <string>

namespace {
uint32_t be32(const uint8_t *p) {
  return uint32_t(p[0]) << 24 | uint32_t(p[1]) << 16 | uint32_t(p[2]) << 8 | p[3];
}
void check(int result) {
  if (result >= 0) return;
  char message[AV_ERROR_MAX_STRING_SIZE];
  av_strerror(result, message, sizeof(message));
  throw std::invalid_argument(std::string("ALAC: ") + message);
}
}

namespace yuzic {
AlacDecoder::AlacDecoder(const uint8_t *cookie, size_t size) {
  if (size != 24) throw std::invalid_argument("Expected 24-byte ALACSpecificConfig");
  frameLength_ = be32(cookie);
  channels_ = cookie[9];
  sampleRate_ = be32(cookie + 20);
  const unsigned depth = cookie[5];
  if (!frameLength_ || frameLength_ > 65536 || cookie[4] != 0 || channels_ < 1 || channels_ > 8
      || (depth != 16 && depth != 20 && depth != 24 && depth != 32)
      || cookie[8] > 31 || !sampleRate_ || sampleRate_ > 768000) {
    throw std::invalid_argument("Unsupported ALAC configuration");
  }
  try {
    const AVCodec *codec = avcodec_find_decoder(AV_CODEC_ID_ALAC);
    if (!codec) throw std::runtime_error("FFmpeg was built without ALAC");
    context_ = avcodec_alloc_context3(codec);
    frame_ = av_frame_alloc();
    packet_ = av_packet_alloc();
    if (!context_ || !frame_ || !packet_) throw std::bad_alloc();
    // Media3 supplies a bare config; FFmpeg expects the surrounding ALAC atom.
    context_->extradata_size = 36;
    context_->extradata = static_cast<uint8_t *>(av_mallocz(36 + AV_INPUT_BUFFER_PADDING_SIZE));
    if (!context_->extradata) throw std::bad_alloc();
    const uint8_t header[12] = {0, 0, 0, 36, 'a', 'l', 'a', 'c', 0, 0, 0, 0};
    std::memcpy(context_->extradata, header, 12);
    std::memcpy(context_->extradata + 12, cookie, 24);
    context_->thread_count = 1;
    context_->err_recognition = AV_EF_CAREFUL | AV_EF_EXPLODE;
    check(avcodec_open2(context_, codec, nullptr));
    if (context_->ch_layout.nb_channels != int(channels_) || context_->sample_rate != int(sampleRate_)) {
      throw std::invalid_argument("ALAC configuration does not match decoder output");
    }
  } catch (...) {
    av_packet_free(&packet_);
    av_frame_free(&frame_);
    avcodec_free_context(&context_);
    throw;
  }
}

AlacDecoder::~AlacDecoder() {
  av_packet_free(&packet_);
  av_frame_free(&frame_);
  avcodec_free_context(&context_);
}

void AlacDecoder::flush() { avcodec_flush_buffers(context_); }

size_t AlacDecoder::decode(const uint8_t *input, size_t size, uint8_t *pcm, size_t capacity) {
  if (!size || size > size_t(frameLength_) * channels_ * 4 + 65536 || capacity < maxOutputBytes()) {
    throw std::invalid_argument("Invalid ALAC buffer size");
  }
  av_packet_unref(packet_);
  av_frame_unref(frame_);
  // av_new_packet supplies FFmpeg's required zero padding, including after a
  // seek to a shorter final packet. Media3's direct input has no such guarantee.
  check(av_new_packet(packet_, static_cast<int>(size)));
  std::memcpy(packet_->data, input, size);
  check(avcodec_send_packet(context_, packet_));
  check(avcodec_receive_frame(context_, frame_));
  if (frame_->nb_samples <= 0 || frame_->nb_samples > int(frameLength_)
      || frame_->ch_layout.nb_channels != int(channels_) || frame_->sample_rate != int(sampleRate_)
      || (frame_->format != AV_SAMPLE_FMT_S16P && frame_->format != AV_SAMPLE_FMT_S32P)) {
    throw std::invalid_argument("Unexpected ALAC output format");
  }
  // FFmpeg puts channels in the standard speaker order, including multichannel
  // ALAC's different packet ordering. Interleave directly into Media3's output.
  // The graph's EQ/fade processors require PCM16, also for hi-res sources.
  for (int sample = 0; sample < frame_->nb_samples; ++sample) {
    for (unsigned channel = 0; channel < channels_; ++channel) {
      uint16_t value;
      if (frame_->format == AV_SAMPLE_FMT_S16P) {
        value = reinterpret_cast<const uint16_t *>(frame_->extended_data[channel])[sample];
      } else {
        value = static_cast<uint16_t>(reinterpret_cast<const uint32_t *>(frame_->extended_data[channel])[sample] >> 16);
      }
      const size_t offset = (size_t(sample) * channels_ + channel) * 2;
      pcm[offset] = static_cast<uint8_t>(value);
      pcm[offset + 1] = static_cast<uint8_t>(value >> 8);
    }
  }
  return size_t(frame_->nb_samples) * channels_ * 2;
}
}
