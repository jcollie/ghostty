#!/usr/bin/env python3
"""Drive `kitten dnd` against libghostty-vt's drag and drop C API.

libghostty-vt is the terminal: kitten's output is fed to
ghostty_terminal_vt_write and the terminal's replies go back through the
write_pty effect. This script plays the OS side of drag and drop with
ghostty_terminal_drop and ghostty_terminal_drag, and hears what the
kitten did through the drop and drag effects.
"""

import ctypes as C
import fcntl
import json
import os
import select
import shutil
import struct
import subprocess
import sys
import termios
import time

if len(sys.argv) != 4 or sys.argv[2] not in ("drop", "drag"):
    raise SystemExit(f"usage: {sys.argv[0]} LIBGHOSTTY_VT_SO drop|drag WORKDIR")

LIB = sys.argv[1]
SCENARIO = sys.argv[2]
WORKDIR = sys.argv[3]
KITTEN = "kitten"
if shutil.which(KITTEN) is None:
    raise SystemExit("kitten not found on PATH; install kitty to get it")

lib = C.CDLL(LIB)
Terminal = C.c_void_p

# The library describes its own ABI. Enum values come from it, and every
# structure below is checked against it, so the harness can't silently
# drift from the header.
lib.ghostty_type_json.restype = C.c_char_p
TYPES = json.loads(lib.ghostty_type_json())["types"]


def enum(type_name, value):
    return TYPES[type_name]["values"][value]


class String(C.Structure):
    _fields_ = [("ptr", C.c_void_p), ("len", C.c_size_t)]


class Position(C.Structure):
    _fields_ = [("cell_x", C.c_uint32), ("cell_y", C.c_uint32),
                ("pixel_x", C.c_int32), ("pixel_y", C.c_int32)]


class DropMotion(C.Structure):
    _fields_ = [("position", Position), ("operations", C.c_uint32),
                ("mimes", C.POINTER(String)), ("mimes_len", C.c_size_t)]


class DropData(C.Structure):
    _fields_ = [("id", C.c_uint32), ("data", String)]


class DropFailure(C.Structure):
    _fields_ = [("id", C.c_uint32), ("reason", C.c_int)]


class DropInputValue(C.Union):
    _fields_ = [("move", DropMotion), ("drop", DropMotion), ("data", DropData),
                ("id", C.c_uint32), ("fail", DropFailure), ("_padding", C.c_uint64 * 8)]


class DropInput(C.Structure):
    _fields_ = [("tag", C.c_int), ("value", DropInputValue)]


class DropRegistration(C.Structure):
    _fields_ = [("accepting", C.c_bool), ("mimes", C.POINTER(String)), ("mimes_len", C.c_size_t)]


class DropAcceptance(C.Structure):
    _fields_ = [("operation", C.c_int), ("mimes", C.POINTER(String)), ("mimes_len", C.c_size_t)]


class DropDataRequest(C.Structure):
    _fields_ = [("id", C.c_uint32), ("mime_index", C.c_uint32), ("mime", String)]


class DropEventValue(C.Union):
    _fields_ = [("registration", DropRegistration), ("acceptance", DropAcceptance),
                ("data_request", DropDataRequest), ("concluded", C.c_int),
                ("_padding", C.c_uint64 * 8)]


class DropEvent(C.Structure):
    _fields_ = [("tag", C.c_int), ("value", DropEventValue)]


class DragItem(C.Structure):
    _fields_ = [("mime", String), ("has_pre_sent", C.c_bool), ("pre_sent", String)]


class DragImage(C.Structure):
    _fields_ = [("format", C.c_int), ("width", C.c_uint32), ("height", C.c_uint32),
                ("opacity", C.c_uint32), ("data", String)]


class DragOffer(C.Structure):
    _fields_ = [("operations", C.c_uint32),
                ("items", C.POINTER(DragItem)), ("items_len", C.c_size_t),
                ("images", C.POINTER(DragImage)), ("images_len", C.c_size_t),
                ("has_image", C.c_bool), ("image", C.c_uint32)]


class DragImageChange(C.Structure):
    _fields_ = [("has_image", C.c_bool), ("image", C.c_uint32)]


class DragData(C.Structure):
    _fields_ = [("index", C.c_uint32), ("bytes", String), ("status", C.c_int)]


class DragEventValue(C.Union):
    _fields_ = [("enabled", C.c_bool), ("start", DragOffer), ("image", DragImageChange),
                ("data", DragData), ("_padding", C.c_uint64 * 8)]


class DragEvent(C.Structure):
    _fields_ = [("tag", C.c_int), ("value", DragEventValue)]


class DragInputValue(C.Union):
    _fields_ = [("position", Position), ("start_result", C.c_int), ("mime_index", C.c_int32),
                ("operation", C.c_int), ("canceled", C.c_bool), ("index", C.c_uint32),
                ("_padding", C.c_uint64 * 8)]


class DragInput(C.Structure):
    _fields_ = [("tag", C.c_int), ("value", DragInputValue)]


class SizeReport(C.Structure):
    _fields_ = [("rows", C.c_uint16), ("columns", C.c_uint16),
                ("cell_width", C.c_uint32), ("cell_height", C.c_uint32)]


for name, cls in {
    "GhosttyString": String,
    "GhosttyDndPosition": Position,
    "GhosttyDropMotion": DropMotion,
    "GhosttyDropData": DropData,
    "GhosttyDropFailure": DropFailure,
    "GhosttyDropInputValue": DropInputValue,
    "GhosttyDropInput": DropInput,
    "GhosttyDropRegistration": DropRegistration,
    "GhosttyDropAcceptance": DropAcceptance,
    "GhosttyDropDataRequest": DropDataRequest,
    "GhosttyDropEventValue": DropEventValue,
    "GhosttyDropEvent": DropEvent,
    "GhosttyDragItem": DragItem,
    "GhosttyDragImage": DragImage,
    "GhosttyDragOffer": DragOffer,
    "GhosttyDragImageChange": DragImageChange,
    "GhosttyDragData": DragData,
    "GhosttyDragEventValue": DragEventValue,
    "GhosttyDragEvent": DragEvent,
    "GhosttyDragInputValue": DragInputValue,
    "GhosttyDragInput": DragInput,
}.items():
    desc = TYPES[name]
    assert C.sizeof(cls) == desc["size"], f"{name}: size {C.sizeof(cls)} != {desc['size']}"
    if desc["kind"] == "struct":
        for field, info in desc["fields"].items():
            got = getattr(cls, field).offset
            assert got == info["offset"], f"{name}.{field}: offset {got} != {info['offset']}"

WritePtyFn = C.CFUNCTYPE(None, Terminal, C.c_void_p, C.POINTER(C.c_uint8), C.c_size_t)
DropFn = C.CFUNCTYPE(None, Terminal, C.c_void_p, C.POINTER(DropEvent))
DragFn = C.CFUNCTYPE(None, Terminal, C.c_void_p, C.POINTER(DragEvent))
SizeFn = C.CFUNCTYPE(C.c_bool, Terminal, C.c_void_p, C.POINTER(SizeReport))

SUCCESS = 0
OPS_COPY = 1

for name, argtypes in {
    "ghostty_terminal_new": [C.c_void_p, C.POINTER(Terminal), C.c_uint16, C.c_uint16],
    "ghostty_terminal_set": [Terminal, C.c_int, C.c_void_p],
    "ghostty_terminal_vt_write": [Terminal, C.c_char_p, C.c_size_t],
    "ghostty_terminal_drop": [Terminal, C.POINTER(DropInput)],
    "ghostty_terminal_drag": [Terminal, C.POINTER(DragInput)],
}.items():
    getattr(lib, name).argtypes = argtypes
    if name != "ghostty_terminal_vt_write":
        getattr(lib, name).restype = C.c_int


def show(b):
    return b.decode("utf-8", "replace").replace("\x1b", "ESC").replace("\x07", "BEL")


def string(s):
    return C.string_at(s.ptr, s.len) if s.len else b""


def strings(ptr, length):
    return [string(ptr[i]) for i in range(length)]


# The pty.
master, slave = os.openpty()
fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 24, 80, 480, 800))

if SCENARIO == "drop":
    argv = [KITTEN, "dnd", "--drop-anywhere=copy", "--drop", "text/plain:out.txt"]
else:
    with open(os.path.join(WORKDIR, "in.txt"), "w") as f:
        f.write("dragged from kitten\n")
    argv = [KITTEN, "dnd", "--drag", "text/plain:in.txt"]


def make_controlling_tty():
    os.setsid()
    fcntl.ioctl(0, termios.TIOCSCTTY, 0)


proc = subprocess.Popen(argv, stdin=slave, stdout=slave, stderr=slave, cwd=WORKDIR,
                        preexec_fn=make_controlling_tty)
os.close(slave)

# Events as (name, details), copied out of the callbacks since what an
# event borrows is only valid during the call.
events = []
RAW = open(os.path.join(WORKDIR, "raw.bin"), "wb")

DROP_EVENTS = {v: k.lower() for k, v in TYPES["GhosttyDropEventTag"]["values"].items()}
DRAG_EVENTS = {v: k.lower() for k, v in TYPES["GhosttyDragEventTag"]["values"].items()}


@WritePtyFn
def write_pty(_t, _ud, data, length):
    b = C.string_at(data, length)
    print(f"  terminal -> kitten: {show(b)}")
    os.write(master, b)


@DropFn
def on_drop(_t, _ud, ev_ptr):
    ev = ev_ptr.contents
    name = DROP_EVENTS[ev.tag]
    v = ev.value
    if name == "registration":
        details = (v.registration.accepting, strings(v.registration.mimes, v.registration.mimes_len))
    elif name == "acceptance":
        details = (v.acceptance.operation, strings(v.acceptance.mimes, v.acceptance.mimes_len))
    elif name == "data_request":
        details = (v.data_request.id, v.data_request.mime_index, string(v.data_request.mime))
    else:
        details = v.concluded
    print(f"  drop event: {name} {details!r}")
    events.append((name, details))


@DragFn
def on_drag(_t, _ud, ev_ptr):
    ev = ev_ptr.contents
    name = DRAG_EVENTS[ev.tag]
    v = ev.value
    if name == "offers":
        details = v.enabled
    elif name == "start":
        o = v.start
        details = [(string(o.items[i].mime),
                    string(o.items[i].pre_sent) if o.items[i].has_pre_sent else None)
                   for i in range(o.items_len)]
    elif name == "data":
        details = (v.data.index, string(v.data.bytes), v.data.status)
    else:
        details = None
    print(f"  drag event: {name} {details!r}")
    events.append((name, details))


@SizeFn
def size_cb(_t, _ud, out):
    out.contents.rows, out.contents.columns = 24, 80
    out.contents.cell_width, out.contents.cell_height = 10, 20
    return True


term = Terminal()
assert lib.ghostty_terminal_new(None, C.byref(term), 80, 24) == SUCCESS
for opt, fn in (("WRITE_PTY", write_pty), ("SIZE", size_cb), ("DROP", on_drop), ("DRAG", on_drag)):
    lib.ghostty_terminal_set(term, enum("GhosttyTerminalOption", opt), C.cast(fn, C.c_void_p))


def pump(timeout):
    """Feed kitten's output to the terminal until quiet for `timeout`."""
    while True:
        r, _, _ = select.select([master], [], [], timeout)
        if not r:
            return
        try:
            b = os.read(master, 65536)
        except OSError:
            return
        if not b:
            return
        dnd = [p for p in b.split(b"\x1b]") if p.startswith(b"72;")]
        for p in dnd:
            print(f"  kitten -> terminal: {p.split(b'\x1b')[0]!r}")
        RAW.write(b)
        lib.ghostty_terminal_vt_write(term, b, len(b))


def take(name):
    """Remove and return the details of the oldest `name` event, or
    raise LookupError if there is none."""
    for i, (n, details) in enumerate(events):
        if n == name:
            del events[i]
            return details
    raise LookupError(name)


def wait_for(name, timeout=10):
    deadline = time.time() + timeout
    while True:
        try:
            return take(name)
        except LookupError:
            pass
        if time.time() > deadline:
            raise SystemExit(f"FAIL: timed out waiting for {name}")
        pump(0.2)


def drop(tag, **value):
    inp = DropInput(tag=enum("GhosttyDropInputTag", tag))
    for k, v in value.items():
        setattr(inp.value, k, v)
    return lib.ghostty_terminal_drop(term, C.byref(inp))


def drag(tag, **value):
    inp = DragInput(tag=enum("GhosttyDragInputTag", tag))
    for k, v in value.items():
        setattr(inp.value, k, v)
    return lib.ghostty_terminal_drag(term, C.byref(inp))


POS = Position(2, 1, 25, 30)
text = b"hello from ghostty\n"

if SCENARIO == "drop":
    accepting, _ = wait_for("registration")
    assert accepting, "FAIL: registration without accepting drops"
    mimes = (String * 1)(String(C.cast(C.c_char_p(b"text/plain"), C.c_void_p), 10))
    motion = DropMotion(POS, OPS_COPY, mimes, 1)
    print("OS: drag moves over the terminal")
    assert drop("MOVE", move=motion) == SUCCESS
    op, _ = wait_for("acceptance")
    print(f"OS: client accepts operation {op}")
    print("OS: drop")
    assert drop("DROP", drop=motion) == SUCCESS

    # Requests are answered after the effect returned, as an embedder
    # reading the native drop asynchronously does. Answering one hands
    # out the next through the effect.
    req = wait_for("data_request")
    while req is not None:
        req_id, _, mime = req
        print(f"OS: serving {mime!r}")
        data = DropData(req_id, String(C.cast(C.c_char_p(text), C.c_void_p), len(text)))
        assert drop("DATA", data=data) == SUCCESS
        assert drop("END", id=req_id) == SUCCESS
        try:
            req = take("data_request")
        except LookupError:
            req = None

    op = wait_for("concluded")
    print(f"OS: drop concluded with operation {op}")
    pump(0.5)
    out = os.path.join(WORKDIR, "out.txt")
    got = open(out, "rb").read() if os.path.exists(out) else None
    print(f"out.txt: {got!r}")
    assert got == text, "FAIL: dropped data not written"
else:
    assert wait_for("offers"), "FAIL: offers disabled"
    print("OS: drag gesture")
    assert drag("GESTURE", position=POS) == SUCCESS
    items = wait_for("start")
    for mime, pre in items:
        print(f"OS: offered {mime!r} pre-sent {pre!r}")
    mimes = [mime for mime, _ in items]
    assert drag("START_RESULT", start_result=enum("GhosttyDragStartResult", "STARTED")) == SUCCESS
    pump(0.5)

    print("OS: target accepts text/plain, copy, drops, and asks for the data")
    idx = mimes.index(b"text/plain")
    assert drag("ACCEPTED", mime_index=idx) == SUCCESS
    assert drag("OPERATION", operation=enum("GhosttyDndOperation", "COPY")) == SUCCESS
    assert drag("DROPPED") == SUCCESS
    assert drag("REQUEST_DATA", index=idx) == SUCCESS

    pending = enum("GhosttyDragDataStatus", "PENDING")
    got = b""
    while True:
        index, data, status = wait_for("data")
        assert index == idx, f"FAIL: data for item {index}"
        got += data
        if status != pending:
            print(f"OS: data status {status}: {got!r}")
            break
    assert drag("FINISHED", canceled=False) == SUCCESS
    pump(0.5)
    assert got == b"dragged from kitten\n", "FAIL: wrong drag data"

os.write(master, b"\x03")
try:
    proc.wait(timeout=5)
except subprocess.TimeoutExpired:
    proc.kill()
print("PASS")
