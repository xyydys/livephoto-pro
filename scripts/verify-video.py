#!/usr/bin/env python3
"""Compare the first non-thumbnail video track of two local files using ffprobe."""

import argparse
from fractions import Fraction
import json
from pathlib import Path
import struct
import subprocess
import sys


def boxes(file, start, end):
    """Yield direct ISO base media file format children, skipping media by seeking."""
    while start + 8 <= end:
        file.seek(start)
        size, kind = struct.unpack(">I4s", file.read(8))
        header = 8
        if size == 1:
            size, = struct.unpack(">Q", file.read(8))
            header = 16
        elif size == 0:
            size = end - start
        if size < header or start + size > end:
            raise ValueError(f"Invalid MOV box {kind!r} at byte {start}")
        yield kind, start + header, start + size
        start += size


def descendants(file, start, end, *path):
    levels = [(start, end)]
    for child in path:
        levels = [
            (a, b) for begin, stop in levels
            for kind, a, b in boxes(file, begin, stop) if kind == child
        ]
    return levels


def mov_apertures(file, start, end):
    # A VisualSampleEntry has a fixed 78-byte header before its extension boxes.
    levels = descendants(file, start, end, b"mdia", b"minf", b"stbl", b"stsd")
    apertures = []
    for a, b in levels:
        for _, entry, stop in boxes(file, a + 8, b):
            for kind, pos, last in boxes(file, entry + 78, stop):
                if kind == b"clap":
                    if last - pos != 32:
                        raise ValueError("Invalid clean aperture box")
                    file.seek(pos)
                    values = struct.unpack(">IIIIiIiI", file.read(32))
                    apertures.append(tuple(Fraction(n, d) for n, d in zip(values[::2], values[1::2])))
    return apertures


def mov_geometry(path, track_id):
    with path.open("rb") as file:
        for start, end in descendants(file, 0, path.stat().st_size, b"moov", b"trak"):
            for pos, last in descendants(file, start, end, b"tkhd"):
                file.seek(pos)
                version = file.read(1)
                file.seek(pos + (20 if version == b"\x01" else 12))
                if int.from_bytes(file.read(4), "big") != track_id:
                    continue
                file.seek(last - 8)
                dimensions = struct.unpack(">II", file.read(8))
                geometry = {
                    "MOV track display size": tuple(Fraction(v, 65536) for v in dimensions),
                    "MOV clean apertures": mov_apertures(file, start, end),
                }
                for a, b in descendants(file, start, end, b"tapt"):
                    for kind, pos, last in boxes(file, a, b):
                        if kind in (b"clef", b"prof", b"enof") and last - pos == 12:
                            file.seek(pos + 4)
                            values = struct.unpack(">II", file.read(8))
                            geometry[f"MOV {kind.decode()} aperture"] = tuple(
                                Fraction(value, 65536) for value in values
                            )
                return geometry
    raise ValueError(f"{path}: could not find MOV track {track_id}")


def load_video(path):
    command = [
        "ffprobe", "-v", "error", "-select_streams", "V:0", "-show_data_hash", "sha256",
        "-show_streams", "-show_packets", "-show_entries",
        "format=format_name:stream:stream_side_data:packet=pts,dts,duration,data_hash",
        "-of", "json", str(path.resolve()),
    ]
    result = subprocess.run(command, capture_output=True, text=True, check=False)
    if result.returncode:
        raise ValueError(f"{path}: {result.stderr.strip()}")
    data = json.loads(result.stdout)
    if not data.get("streams") or not data.get("packets"):
        raise ValueError(f"{path}: no non-thumbnail video track with packets")
    stream = data["streams"][0]
    fields = (
        "codec_name", "profile", "extradata_hash", "width", "height", "coded_width",
        "coded_height", "sample_aspect_ratio", "display_aspect_ratio", "pix_fmt",
        "color_range", "color_space", "color_transfer", "color_primaries",
        "chroma_location", "field_order", "bits_per_raw_sample", "side_data_list",
    )
    metadata = {field: stream.get(field) for field in fields}
    metadata["rotate tag"] = stream.get("tags", {}).get("rotate")
    if "mov" in data["format"]["format_name"].split(","):
        metadata.update(mov_geometry(path, int(stream["id"], 0)))

    packets = data["packets"]
    if any("pts" not in p or "data_hash" not in p for p in packets):
        raise ValueError(f"{path}: cannot verify all packet timestamps and hashes")
    scale = Fraction(stream["time_base"])
    first = min(p["pts"] for p in packets)
    if "duration_ts" in stream:
        metadata["track duration (s)"] = stream["duration_ts"] * scale
    timing = []
    for packet in packets:
        timing.append((
            (packet["pts"] - first) * scale,
            (packet["dts"] - first) * scale if "dts" in packet else None,
            packet["duration"] * scale if "duration" in packet else None,
        ))
    print(f"{path}: {stream['codec_name']} {stream['width']}x{stream['height']}, "
          f"{len(packets)} packets, first PTS {first * scale} s, time base {scale}")
    return metadata, [p["data_hash"] for p in packets], timing


def main():
    parser = argparse.ArgumentParser(description=__doc__, epilog=(
        "Use the original paired MOV exported from Photos. Compare the same complete clip. "
        "Exit 0 = checked properties match, 1 = differences, 2 = could not verify. "
        "Packet differences alone do not prove a lossy encode. This checks the video track only."
    ))
    parser.add_argument("source", type=Path)
    parser.add_argument("paired_mov", type=Path)
    args = parser.parse_args()
    try:
        source, original_bytes, original_times = load_video(args.source)
        paired, paired_bytes, paired_times = load_video(args.paired_mov)
    except (OSError, ValueError, KeyError, struct.error, ZeroDivisionError) as exc:
        print(f"Cannot verify: {exc}", file=sys.stderr)
        return 2

    differences = []
    for key in sorted(source.keys() | paired.keys()):
        if source.get(key) != paired.get(key):
            differences.append(f"{key}: {source.get(key)} -> {paired.get(key)}")
    for label, before, after in (
        ("packet SHA-256", original_bytes, paired_bytes),
        ("relative PTS, DTS and packet duration (s)", original_times, paired_times),
    ):
        if before == after:
            print(f"Match: {label}")
        else:
            if len(before) != len(after):
                differences.append(f"{label} count: {len(before)} -> {len(after)}")
            for index, (a, b) in enumerate(zip(before, after)):
                if a != b:
                    differences.append(f"{label}, first differing packet #{index + 1}: {a} -> {b}")
                    break
    if differences:
        for line in differences:
            print(f"Difference: {line}")
        return 1
    print("Match: codec configuration, reported geometry, stream side data and color properties.")
    if any(None in row for row in original_times):
        print("Note: some DTS or packet durations were unavailable in both files.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
