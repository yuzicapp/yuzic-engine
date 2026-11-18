#include "AlacDecoder.h"
#include <fstream>
#include <iostream>
#include <stdexcept>
#include <vector>

static uint32_t readSize(std::istream &input) {
  uint8_t bytes[4];
  if (!input.read(reinterpret_cast<char *>(bytes), 4)) throw std::runtime_error("Truncated packet file");
  return uint32_t(bytes[0]) << 24 | uint32_t(bytes[1]) << 16 | uint32_t(bytes[2]) << 8 | bytes[3];
}
int main(int argc, char **argv) {
  if (argc != 3) { std::cerr << "Usage: alac_probe packets output.pcm\n"; return 2; }
  try {
    std::ifstream input(argv[1], std::ios::binary);
    std::ofstream output(argv[2], std::ios::binary);
    uint8_t config[24];
    if (!input.read(reinterpret_cast<char *>(config), 24)) throw std::runtime_error("Missing config");
    yuzic::AlacDecoder decoder(config, 24);
    std::vector<uint8_t> pcm(decoder.maxOutputBytes());
    for (uint32_t size; (size = readSize(input)) != UINT32_MAX;) {
      if (size > 4 * 1024 * 1024) throw std::runtime_error("Packet too large");
      std::vector<uint8_t> packet(size);
      if (!input.read(reinterpret_cast<char *>(packet.data()), size)) throw std::runtime_error("Truncated packet");
      size_t decoded = decoder.decode(packet.data(), packet.size(), pcm.data(), pcm.size());
      output.write(reinterpret_cast<const char *>(pcm.data()), decoded);
    }
    if (!output) throw std::runtime_error("Cannot write PCM");
  } catch (const std::exception &error) { std::cerr << error.what() << '\n'; return 1; }
}
