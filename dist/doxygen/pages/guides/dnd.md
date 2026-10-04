# Drag and Drop {#guide-dnd}

Native drag and drop for programs running in the terminal, in both
directions. A program can accept drops: native drags over the terminal
are forwarded to it and it reads the dropped data on request, instead
of the traditional behavior of pasting dropped paths or text. A program
can also offer drags: when the user starts a drag gesture over the
terminal, the program supplies the data, and optionally images, of a
native drag out of the terminal.

libghostty-vt implements the protocol programs use to do this (today
the [Kitty drag and drop protocol](https://sw.kovidgoyal.net/kitty/dnd-protocol/),
OSC 72); the embedder connects it to the operating system. The terminal
tells the embedder what the program did through the
@ref GHOSTTY_TERMINAL_OPT_DROP and @ref GHOSTTY_TERMINAL_OPT_DRAG
effects, and the embedder reports what the user did with
ghostty_terminal_drop() and ghostty_terminal_drag(), which answer the
program through the @ref GHOSTTY_TERMINAL_OPT_WRITE_PTY effect.

Each direction is enabled by setting its effect. Without the drop
effect programs can't register to accept drops, and without the drag
effect their drag offers are refused, so they fall back to their
behavior without drag and drop. With neither, the protocol is ignored
entirely.

Drag and drop was added in libghostty-vt 1.1. With a 1.0 library, setting
#GHOSTTY_TERMINAL_OPT_DROP or #GHOSTTY_TERMINAL_OPT_DRAG returns
GHOSTTY_UNSUPPORTED. See @ref stability-check.

Everything an event borrows is only valid during the effect callback.
ghostty_terminal_drop() and ghostty_terminal_drag() must be called from
the thread that calls ghostty_terminal_vt_write(), and may be called
from within the effect callbacks.

Every program is treated as being on the local machine: transferring
files from a remote machine is not supported, though remote programs
can exchange text and other data.

## Accepting Drops {#guide-dnd-drops}

1. The program registers to accept drops, yielding
   @ref GHOSTTY_DROP_EVENT_REGISTRATION. While it is accepting drops,
   forward native drags over the terminal to it instead of handling
   them yourself.
2. As a native drag moves over the terminal, report it with
   @ref GHOSTTY_DROP_INPUT_MOVE, giving its position, allowed
   operations, and MIME types. When it leaves, report
   @ref GHOSTTY_DROP_INPUT_LEAVE.
3. The program answers with the operation it accepts, yielding
   @ref GHOSTTY_DROP_EVENT_ACCEPTANCE, for the OS drag feedback. Until
   it accepts, the drag isn't accepted.
4. On drop, if the program accepted the drag, report
   @ref GHOSTTY_DROP_INPUT_DROP and keep the native drop open: its data
   is read on demand. If it didn't, refuse the native drop and report
   @ref GHOSTTY_DROP_INPUT_LEAVE: the program would never read or
   conclude it (for example, a drag it started itself).
5. The program requests data, yielding
   @ref GHOSTTY_DROP_EVENT_DATA_REQUEST. Read that MIME type from the
   native drop and answer with any number of
   @ref GHOSTTY_DROP_INPUT_DATA followed by @ref GHOSTTY_DROP_INPUT_END,
   or with @ref GHOSTTY_DROP_INPUT_FAIL. Answering may be
   asynchronous. Requests are served one at a time: the next is
   delivered once the previous one is answered.
6. The program concludes the drop, yielding
   @ref GHOSTTY_DROP_EVENT_CONCLUDED: finish the native drop with the
   operation it performed. A drop the program never concluded is
   concluded with no operation when the next drag arrives.

@snippet c-vt-dnd/src/main.c dnd-drop

Full program: @ref c-vt-dnd/src/main.c

## Offering Drags {#guide-dnd-drags}

1. The program enables offering drags, yielding
   @ref GHOSTTY_DRAG_EVENT_OFFERS. While it offers them, when the user
   starts the platform's drag gesture over the terminal (typically
   dragging with the left button held), report
   @ref GHOSTTY_DRAG_INPUT_GESTURE instead of handling it yourself.
2. The program offers a drag and asks to start it, yielding
   @ref GHOSTTY_DRAG_EVENT_START with the offer. Copy what you need
   of it, start the native drag, and report the result with
   @ref GHOSTTY_DRAG_INPUT_START_RESULT.
3. Report the drag's progress with @ref GHOSTTY_DRAG_INPUT_ACCEPTED,
   @ref GHOSTTY_DRAG_INPUT_OPERATION, and
   @ref GHOSTTY_DRAG_INPUT_DROPPED. When a drop target wants data
   that wasn't pre-sent, report @ref GHOSTTY_DRAG_INPUT_REQUEST_DATA;
   the program's reply arrives as @ref GHOSTTY_DRAG_EVENT_DATA events.
   @ref GHOSTTY_DRAG_EVENT_IMAGE changes the drag image and
   @ref GHOSTTY_DRAG_EVENT_CANCEL cancels the drag.
4. Report @ref GHOSTTY_DRAG_INPUT_FINISHED, which ends the drag.

@snippet c-vt-dnd/src/main.c dnd-drag

Full program: @ref c-vt-dnd/src/main.c
