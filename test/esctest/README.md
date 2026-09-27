# esctest for libghostty-vt

Runs [esctest](https://github.com/ThomasDickey/esctest2), a conformance
suite for terminal emulators, against libghostty-vt without a GUI.

esctest runs under a pty. Everything it writes is fed through a
libghostty-vt `Terminal`, and the terminal's replies (DECRQCRA checksums,
device attributes, cursor position and size reports) are written back to
it. When esctest exits, its log is copied to stdout. A full run takes
about half a minute.

## Usage

The build fetches esctest itself, pinned in `build.zig.zon`, and installs
it in `zig-out/share/esctest`. esctest is Python, so a Python 3 must be on
`PATH` as `python3`.

From this directory:

```sh
zig build run > esctest.log
tail -1 esctest.log
```

Arguments after `--` are passed to esctest. For example, to run only the
DECSTR tests and stop at the first failure:

```sh
zig build run -- --include=DECSTR --stop-on-failure
```

`--verbose`, given before any esctest arguments, shows libghostty-vt's own
log on stderr, which names each sequence that it ignores.

To move to a newer esctest, fetch the commit you want:

```sh
zig fetch --save=esctest2 https://github.com/ThomasDickey/esctest2/archive/<commit>.tar.gz
```

## How the terminal is set up

esctest can only check a terminal that answers like some real one, so the
runner passes it `--expected-terminal=xterm --xterm-checksum=411`, and sets
up the terminal to match:

- An 80x25 screen, the size esctest resets to before each test.
- DECRQCRA enabled, with xterm's `checksumExtension: 23` calculation, which
  is what esctest expects with `--xterm-checksum` 334 or later.
- Device attributes of a VT520, the highest level esctest tests.

The terminal never resizes, so the tests that resize it with XTWINOPS or
DECCOLM fail.
