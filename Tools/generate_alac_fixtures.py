#!/usr/bin/env python3
"""Regenerate native ALAC test packets and PCM references from synthetic tones."""
from pathlib import Path
import subprocess
import tempfile
from verify_android_alac import packets_from_file

destination = Path(__file__).resolve().parent.parent / 'android/src/test/resources/alac'
destination.mkdir(parents=True, exist_ok=True)
with tempfile.TemporaryDirectory(prefix='alac-fixtures-') as directory:
    for depth, channels in [(16, 1), (16, 2), (24, 1), (24, 2), (16, 6), (24, 8)]:
        name = f'{depth}bit-{channels}ch'
        source = Path(directory) / f'{name}.m4a'
        # 4,631 samples: one full 4,096-sample packet and a short final packet.
        expression = '|'.join(f'0.3*sin(2*PI*{431 + channel * 137}*t)' for channel in range(channels))
        subprocess.run(['ffmpeg', '-v', 'error', '-f', 'lavfi', '-i',
                        f'aevalsrc={expression}:s=44100:d=0.105', '-c:a', 'alac',
                        '-sample_fmt', 's16p' if depth == 16 else 's32p', str(source)], check=True)
        packets_from_file(source, destination / f'{name}.packets')
        subprocess.run(['ffmpeg', '-v', 'error', '-y', '-i', str(source),
                        '-f', 's16le', str(destination / f'{name}.pcm')], check=True)
        print(name)
