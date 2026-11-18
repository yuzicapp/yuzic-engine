#include "AlacDecoder.h"
extern "C" {
#include <libavutil/log.h>
}
#include <algorithm>
#include <array>
#include <fstream>
#include <iostream>
#include <iterator>
#include <random>
#include <stdexcept>
#include <vector>

using Bytes = std::vector<uint8_t>;
static void require(bool ok, const char *message) { if (!ok) throw std::runtime_error(message); }
static Bytes read(const std::string &path) {
  std::ifstream file(path, std::ios::binary);
  require(bool(file), "Missing test fixture");
  return Bytes(std::istreambuf_iterator<char>(file), {});
}
template<class F> static void rejects(F action) {
  try { action(); } catch (const std::invalid_argument &) { return; }
  throw std::runtime_error("Malformed input was accepted");
}
static void fixture(const std::string &directory, const std::string &name) {
  Bytes file = read(directory + "/" + name + ".packets");
  Bytes expected = read(directory + "/" + name + ".pcm");
  yuzic::AlacDecoder decoder(file.data(), 24), other(file.data(), 24);
  std::vector<Bytes> packets, outputs;
  Bytes pcm(decoder.maxOutputBytes()), actual;
  size_t cursor = 24;
  while (cursor + 4 <= file.size()) {
    uint32_t size = uint32_t(file[cursor]) << 24 | uint32_t(file[cursor+1]) << 16
        | uint32_t(file[cursor+2]) << 8 | file[cursor+3];
    cursor += 4;
    if (size == UINT32_MAX) break;
    require(size <= file.size() - cursor, "Bad fixture length");
    packets.emplace_back(file.begin() + cursor, file.begin() + cursor + size);
    cursor += size;
    size_t count = decoder.decode(packets.back().data(), size, pcm.data(), pcm.size());
    outputs.emplace_back(pcm.begin(), pcm.begin() + count);
    actual.insert(actual.end(), pcm.begin(), pcm.begin() + count);
    // A second voice must not share codec state with the first.
    size_t otherCount = other.decode(packets.back().data(), size, pcm.data(), pcm.size());
    require(otherCount == count && std::equal(outputs.back().begin(), outputs.back().end(), pcm.begin()), "Voice contamination");
  }
  require(actual == expected, "PCM does not match FFmpeg reference");
  require(outputs.size() >= 2 && outputs.back().size() < outputs.front().size(), "Fixture must have a partial final packet");
  // Seek from the end to the beginning, and straight to the short last packet.
  for (size_t index : {packets.size()-1, size_t(0), packets.size()-1}) {
    decoder.flush();
    size_t count = decoder.decode(packets[index].data(), packets[index].size(), pcm.data(), pcm.size());
    require(count == outputs[index].size() && std::equal(outputs[index].begin(), outputs[index].end(), pcm.begin()), "Seek output differs");
  }
  rejects([&] { decoder.decode(packets[0].data(), packets[0].size(), pcm.data(), pcm.size()-1); });
  rejects([&] { decoder.decode(packets[0].data(), 0, pcm.data(), pcm.size()); });
  for (size_t size : {size_t(1), size_t(2), packets[0].size()/2}) {
    decoder.flush();
    rejects([&] { decoder.decode(packets[0].data(), size, pcm.data(), pcm.size()); });
  }
  // Exercise corrupted headers/residuals against the actual native decoder.
  // With sanitizers enabled these also detect reads/writes outside its buffers.
  std::mt19937 random(1234);
  for (int iteration = 0; iteration < 2000; ++iteration) {
    Bytes bad = packets[iteration % packets.size()];
    for (int change = 0; change < 3; ++change) bad[random() % bad.size()] ^= 1u << (random() % 8);
    decoder.flush();
    try { decoder.decode(bad.data(), bad.size(), pcm.data(), pcm.size()); }
    catch (const std::invalid_argument &) {}
  }
  decoder.flush();
  size_t count = decoder.decode(packets[0].data(), packets[0].size(), pcm.data(), pcm.size());
  require(count == outputs[0].size() && std::equal(outputs[0].begin(), outputs[0].end(), pcm.begin()), "Bad packet poisoned decoder");
  std::cout << name << ": PCM, partial packet, seek, two voices and malformed inputs passed\n";
}

static void rawHighDepth(unsigned depth, unsigned channels) {
  // Independent uncompressed ALAC frames verify 20/32-bit signed conversion;
  // FFmpeg's encoder emits only 16/24-bit streams for the file fixtures.
  std::array<uint8_t, 24> config = {0, 0, 0, 4, 0, 0, 40, 10, 14, 0,
                                  0, 255, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 172, 68};
  config[5] = depth; config[9] = channels;
  Bytes packet;
  size_t bit = 0;
  auto write = [&](uint32_t value, unsigned count) {
    for (unsigned i = count; i > 0; --i, ++bit) {
      if (bit / 8 == packet.size()) packet.push_back(0);
      packet[bit / 8] |= ((value >> (i-1)) & 1) << (7 - bit % 8);
    }
  };
  write(channels-1, 3); write(0, 4); write(0, 12);
  write(1, 1); write(depth == 32 && channels == 2 ? 2 : 0, 2); write(1, 1); write(4, 32);
  const uint32_t values[] = {0, 1u << (depth-1), (1u << (depth-1))-1, 0xffff0000u};
  Bytes expected;
  for (uint32_t value : values) {
    for (unsigned channel = 0; channel < channels; ++channel) {
      write(value, depth);
      uint16_t output = uint16_t(value >> (depth-16));
      expected.push_back(uint8_t(output)); expected.push_back(uint8_t(output >> 8));
    }
  }
  write(7, 3);
  yuzic::AlacDecoder decoder(config.data(), config.size());
  Bytes pcm(decoder.maxOutputBytes());
  size_t size = decoder.decode(packet.data(), packet.size(), pcm.data(), pcm.size());
  require(size == expected.size() && pcm == expected, "High-depth PCM conversion differs");
}
int main(int argc, char **argv) {
  if (argc != 2) return 2;
  av_log_set_level(AV_LOG_QUIET);
  try {
    for (const char *name : {"16bit-1ch", "16bit-2ch", "24bit-1ch", "24bit-2ch", "16bit-6ch", "24bit-8ch"}) fixture(argv[1], name);
    for (unsigned depth : {20u, 32u}) for (unsigned channels : {1u, 2u}) rawHighDepth(depth, channels);
    Bytes file = read(std::string(argv[1]) + "/16bit-2ch.packets");
    rejects([&] { yuzic::AlacDecoder invalid(file.data(), 23); });
    for (size_t index : {size_t(0), size_t(4), size_t(5), size_t(8), size_t(9), size_t(20)}) {
      Bytes bad(file.begin(), file.begin() + 24);
      bad[index] = 255;
      rejects([&] { yuzic::AlacDecoder invalid(bad.data(), bad.size()); });
    }
  } catch (const std::exception &error) { std::cerr << error.what() << '\n'; return 1; }
}
