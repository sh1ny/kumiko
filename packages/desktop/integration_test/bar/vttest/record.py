"""Records the vttest transcripts the terminal bar test replays.

Usage (Linux, Python 3 standard library only):
    python3 record.py <path to vttest> <output dir>

Runs one vttest session in an 80x24 pseudo-terminal and walks main menu
items 1, 2 and 3 with the keystrokes in STEPS, which must match `vttestSteps`
in `../vttest.dart`. Each step's key is sent once the previous output has
been idle for two seconds; `<id>.bin` holds the bytes vttest wrote after it.
The device attributes query is answered as `ESC [ ? 6 c`, as
flutter_alacritty answers it, so vttest takes the same paths it takes live.
"""
import fcntl
import os
import pty
import select
import struct
import sys
import termios
import time

STEPS = [(None, 'menu.0')]
STEPS += [(b'1\r', '1.1')] + [(b'\r', f'1.{i}') for i in range(2, 7)]
STEPS += [(b'\r', 'menu.1')]
STEPS += [(b'2\r', '2.1')] + [(b'\r', f'2.{i}') for i in range(2, 16)]
STEPS += [(b'\r', 'menu.2')]
STEPS += [(b'3\r', '3.1'), (b'\r', 'menu.3')]

DA_QUERIES = (b'\x1b[c', b'\x1b[0c')


def main(vttest, out):
    os.makedirs(out, exist_ok=True)
    pid, fd = pty.fork()
    if pid == 0:
        os.environ['TERM'] = 'vt100'
        os.execv(vttest, [vttest])
    fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack('HHHH', 24, 80, 0, 0))

    def drain(idle=2.0, limit=60.0):
        buf = b''
        start = last = time.time()
        while time.time() - last < idle and time.time() - start < limit:
            ready, _, _ = select.select([fd], [], [], 0.05)
            if not ready:
                continue
            data = os.read(fd, 65536)
            if not data:
                break
            if any(q in data for q in DA_QUERIES):
                os.write(fd, b'\x1b[?6c')
            buf += data
            last = time.time()
        return buf

    for key, step in STEPS:
        if key:
            os.write(fd, key)
        data = drain()
        with open(os.path.join(out, step + '.bin'), 'wb') as f:
            f.write(data)
        print(step, len(data))
    os.kill(pid, 9)


if __name__ == '__main__':
    main(sys.argv[1], sys.argv[2])
