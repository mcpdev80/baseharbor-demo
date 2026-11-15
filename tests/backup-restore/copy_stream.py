#!/usr/bin/env python3
"""Copy stdin bytes to stdout and an artifact file, like tee without text decoding."""
import sys


def main():
    if len(sys.argv) != 2:
        print("usage: copy_stream.py ARTIFACT", file=sys.stderr)
        return 2
    with open(sys.argv[1], "wb") as artifact:
        while True:
            chunk = sys.stdin.buffer.read(65536)
            if not chunk:
                break
            artifact.write(chunk)
            sys.stdout.buffer.write(chunk)
            sys.stdout.buffer.flush()
        artifact.flush()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
