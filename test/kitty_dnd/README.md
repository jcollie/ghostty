# Kitty drag and drop interop harness

`harness.py` tests libghostty-vt's drag and drop, which programs use
through the
[Kitty drag and drop protocol](https://sw.kovidgoyal.net/kitty/dnd-protocol/)
(OSC 72), against kitty's own client, `kitten dnd`.

libghostty-vt is the terminal: the harness runs `kitten dnd` in a pty,
feeds everything it writes to `ghostty_terminal_vt_write`, and sends the
terminal's replies back through the `write_pty` effect. The harness plays
the operating system's side of drag and drop with `ghostty_terminal_drop`
and `ghostty_terminal_drag` from `ghostty/vt/dnd.h`, hears what the kitten
did through the drop and drag effects, then checks that the data arrived
intact.

It runs four scenarios:

- `drop`: the kitten registers to accept drops. The harness moves a drag
  carrying `text/plain` over the terminal, waits for the kitten to accept
  it, drops it, and serves the kitten's data request once the drop effect
  has returned, as an embedder reading a native drop asynchronously does. It passes when the
  kitten concludes the drop and has written the data to `out.txt`.
- `remote-drop`: the harness gives the terminal a machine ID that isn't
  this machine's, so the kitten, which declares this machine's, counts as
  a program on another machine. The harness drops a `text/uri-list`
  naming a file and a directory tree (with a subdirectory and a symbolic
  link) kept beside the working directory, and answers the kitten's file
  requests the way an embedder would, reading the files without following
  symbolic links. It passes when the kitten concludes the drop and its
  copies in the working directory match the originals.
- `drag`: the kitten offers to drag `in.txt` as `text/plain`. The harness
  performs the drag gesture, starts the drag when the kitten asks, reports
  that a target accepted and dropped it, and requests the data. It passes
  when the data received matches the file.
- `remote-drag`: with a machine ID that isn't this machine's, as in
  `remote-drop`, the kitten drags the same file and directory tree. The
  harness starts the drag, requests the `text/uri-list`, and writes the
  files that arrive under `spool` in the working directory the way an
  embedder would. It passes when the list follows the files and the copies
  match the originals.

## Requirements

- Linux or macOS, with Python 3.12 or later.
- `kitten` on your `PATH`. It comes with [kitty](https://sw.kovidgoyal.net/kitty/);
  you don't need to run kitty itself. kitten 0.48.2 and 0.49.0 are known
  to pass.
- A shared libghostty-vt built from this repository (see below).

## Usage

From the root of the repository, build the shared library:

```console
$ zig build -Demit-lib-vt
```

Then run a scenario, giving it the library and an empty working
directory, which becomes the kitten's working directory:

```console
$ mkdir -p /tmp/dnd-drop /tmp/dnd-drag /tmp/dnd-remote-drop /tmp/dnd-remote-drag
$ python3 test/kitty_dnd/harness.py zig-out/lib/libghostty-vt.so drop /tmp/dnd-drop
$ python3 test/kitty_dnd/harness.py zig-out/lib/libghostty-vt.so drag /tmp/dnd-drag
$ python3 test/kitty_dnd/harness.py zig-out/lib/libghostty-vt.so remote-drop /tmp/dnd-remote-drop
$ python3 test/kitty_dnd/harness.py zig-out/lib/libghostty-vt.so remote-drag /tmp/dnd-remote-drag
```

On macOS the library is `zig-out/lib/libghostty-vt.dylib`.

kitty isn't part of the Nix dev shell. Without it installed, you can run
the harness the way CI does, with kitty and Python from the flake's
nixpkgs:

```console
$ nix shell --inputs-from . nixpkgs#kitty nixpkgs#python3 -c \
    python3 test/kitty_dnd/harness.py zig-out/lib/libghostty-vt.so drop /tmp/dnd-drop
```

## CI

The `test-kitty-dnd` job in `.github/workflows/test.yml` runs every
scenario on Linux this way, using the kitty in the flake's pinned
nixpkgs.

The harness prints the protocol conversation as it goes, then `PASS`, or
exits with a `FAIL:` message naming what didn't happen in time. Use a
fresh directory for each run, since the drop scenario checks `out.txt`.

## Output

- Lines starting `terminal -> kitten` are what libghostty-vt wrote to the
  pty.
- Lines starting `kitten -> terminal` are the kitten's OSC 72 packets.
  Only packets that arrived within a single read from the pty are shown,
  so one split across reads is missing from this log even though the
  terminal received it.
- `drop event:` and `drag event:` lines are the `GhosttyDropEvent`s and
  `GhosttyDragEvent`s delivered to the harness, and `OS:` lines are what
  it did in response.

Everything the kitten wrote is saved to `raw.bin` in the working
directory. To list its complete OSC 72 packets:

```console
$ python3 -c "
import re, sys
d = open(sys.argv[1], 'rb').read()
for m in re.finditer(rb'\x1b\]72;([^\x1b\x07]*)', d): print(m.group(1))
" /tmp/dnd-drag/raw.bin
```

## Limitations

- The structures are declared by hand with `ctypes`. Enum values are read
  from the library's ABI manifest (`ghostty_type_json`), and every
  structure's size and field offsets are checked against it at startup, so
  a change to the C API fails the harness immediately rather than
  corrupting memory.
