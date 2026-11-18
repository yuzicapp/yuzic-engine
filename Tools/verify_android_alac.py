#!/usr/bin/env python3
"""Compare the native Android ALAC decoder with FFmpeg on a real M4A (CMake + FFmpeg required)."""
import argparse
import hashlib
import json
from pathlib import Path
import struct
import subprocess
import tempfile


def packets_from_file(source, destination):
    probe = json.loads(subprocess.check_output([
        'ffprobe', '-v', 'error', '-select_streams', 'a:0', '-show_streams',
        '-show_packets', '-show_data', '-show_entries',
        'stream=codec_name,extradata:packet=pos,size', '-of', 'json', str(source),
    ]))
    stream = probe['streams'][0]
    if stream['codec_name'] != 'alac':
        raise ValueError('Expected ALAC audio')
    extra = bytes.fromhex(''.join(
        line.split(':', 1)[1].split('  ', 1)[0].replace(' ', '')
        for line in stream['extradata'].strip().splitlines()
    ))
    # FFmpeg exposes the complete 36-byte atom; Media3 exposes only the config.
    cookie = extra[-24:]
    with open(source, 'rb') as original, open(destination, 'wb') as output:
        output.write(cookie)
        for packet in probe['packets']:
            size = int(packet['size'])
            original.seek(int(packet['pos']))
            output.write(struct.pack('>i', size))
            output.write(original.read(size))
        output.write(struct.pack('>i', -1))
    return len(probe['packets'])


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('file', type=Path)
    parser.add_argument('--ffmpeg-source', type=Path, help='Optional offline FFmpeg source tree')
    parser.add_argument('--build-dir', type=Path, help='Reuse a native CMake build')
    args = parser.parse_args()
    root = Path(__file__).resolve().parent.parent
    with tempfile.TemporaryDirectory(prefix='yuzic-alac-') as temp:
        temp = Path(temp)
        count = packets_from_file(args.file, temp / 'packets')
        build = (args.build_dir or temp / 'build').resolve()
        configure = ['cmake', '-S', str(root / 'android/src/main/cpp'), '-B', str(build),
                     '-DCMAKE_BUILD_TYPE=Release']
        if args.ffmpeg_source:
            configure.append(f'-DYUZIC_FFMPEG_SOURCE={args.ffmpeg_source.resolve()}')
        subprocess.run(configure, check=True)
        subprocess.run(['cmake', '--build', str(build), '--parallel', '2'], check=True)
        subprocess.run([str(build / 'alac_probe'),
                        str(temp / 'packets'), str(temp / 'actual.pcm')], check=True)
        subprocess.run(['ffmpeg', '-v', 'error', '-i', str(args.file), '-map', '0:a:0',
                        '-f', 's16le', '-acodec', 'pcm_s16le', str(temp / 'expected.pcm')], check=True)
        actual = (temp / 'actual.pcm').read_bytes()
        expected = (temp / 'expected.pcm').read_bytes()
        if actual != expected:
            raise AssertionError(f'PCM differs: Android {len(actual)} bytes, FFmpeg {len(expected)} bytes')
        print(f'{count} packets, {len(actual)} PCM bytes: identical to FFmpeg (SHA256 {hashlib.sha256(actual).hexdigest()})')


if __name__ == '__main__':
    main()
