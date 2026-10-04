/**
 * @file dnd.h
 *
 * Native drag and drop for programs running in the terminal.
 *
 * See @ref dnd for a full usage guide.
 */

#ifndef GHOSTTY_VT_DND_H
#define GHOSTTY_VT_DND_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <ghostty/vt/types.h>

#ifdef __cplusplus
extern "C" {
#endif

/** @defgroup dnd Drag and Drop
 *
 * Native drag and drop for programs running in the terminal, in both
 * directions. A program can accept drops: native drags over the terminal
 * are forwarded to it and it reads the dropped data on request, instead
 * of the traditional behavior of pasting dropped paths or text. A program
 * can also offer drags: when the user starts a drag gesture over the
 * terminal, the program supplies the data, and optionally images, of a
 * native drag out of the terminal.
 *
 * libghostty-vt implements the protocol programs use to do this (today
 * the [Kitty drag and drop protocol](https://sw.kovidgoyal.net/kitty/dnd-protocol/),
 * OSC 72); the embedder connects it to the operating system. The terminal
 * tells the embedder what the program did through the
 * @ref GHOSTTY_TERMINAL_OPT_DROP and @ref GHOSTTY_TERMINAL_OPT_DRAG
 * effects, and the embedder reports what the user did with
 * ghostty_terminal_drop() and ghostty_terminal_drag(), which answer the
 * program through the @ref GHOSTTY_TERMINAL_OPT_WRITE_PTY effect.
 *
 * Each direction is enabled by setting its effect. Without the drop
 * effect programs can't register to accept drops, and without the drag
 * effect their drag offers are refused, so they fall back to their
 * behavior without drag and drop. With neither, the protocol is ignored
 * entirely.
 *
 * Everything an event borrows is only valid during the effect callback.
 * ghostty_terminal_drop() and ghostty_terminal_drag() must be called from
 * the thread that calls ghostty_terminal_vt_write(), and may be called
 * from within the effect callbacks.
 *
 * ## Accepting Drops
 *
 *   1. The program registers to accept drops, yielding
 *      @ref GHOSTTY_DROP_EVENT_REGISTRATION. While it is accepting drops,
 *      forward native drags over the terminal to it instead of handling
 *      them yourself.
 *   2. As a native drag moves over the terminal, report it with
 *      @ref GHOSTTY_DROP_INPUT_MOVE, giving its position, allowed
 *      operations, and MIME types. When it leaves, report
 *      @ref GHOSTTY_DROP_INPUT_LEAVE.
 *   3. The program answers with the operation it accepts, yielding
 *      @ref GHOSTTY_DROP_EVENT_ACCEPTANCE, for the OS drag feedback. Until
 *      it accepts, the drag isn't accepted.
 *   4. On drop, if the program accepted the drag, report
 *      @ref GHOSTTY_DROP_INPUT_DROP and keep the native drop open: its data
 *      is read on demand. If it didn't, refuse the native drop and report
 *      @ref GHOSTTY_DROP_INPUT_LEAVE: the program would never read or
 *      conclude it (for example, a drag it started itself).
 *   5. The program requests data, yielding
 *      @ref GHOSTTY_DROP_EVENT_DATA_REQUEST. Read that MIME type from the
 *      native drop and answer with any number of
 *      @ref GHOSTTY_DROP_INPUT_DATA followed by @ref GHOSTTY_DROP_INPUT_END,
 *      or with @ref GHOSTTY_DROP_INPUT_FAIL. Answering may be
 *      asynchronous. Requests are served one at a time: the next is
 *      delivered once the previous one is answered.
 *   6. The program concludes the drop, yielding
 *      @ref GHOSTTY_DROP_EVENT_CONCLUDED: finish the native drop with the
 *      operation it performed. A drop the program never concluded is
 *      concluded with no operation when the next drag arrives.
 *
 * @snippet c-vt-dnd/src/main.c dnd-drop
 *
 * ## Accepting Drops from Remote Programs
 *
 * A program on another machine (e.g. over ssh) can't open the files a
 * drop names, so it copies them through the terminal. Set
 * @ref GHOSTTY_TERMINAL_OPT_DND_MACHINE_ID to this machine's ID so the
 * terminal can tell such programs apart; without it, every program is
 * treated as local, which is safe but leaves remote programs only the
 * dropped text.
 *
 * A remote program reads the drop's `text/uri-list` as usual, then asks
 * for the files it names, and for the entries of directories among them.
 * Each arrives as @ref GHOSTTY_DROP_EVENT_DATA_REQUEST with `has_path`
 * set: a file request. Look at the path without following symbolic
 * links, report what it is with @ref GHOSTTY_DROP_INPUT_KIND, then send
 * its data like any other request: a regular file's contents, a symbolic
 * link's target, or a directory's entries that are regular files,
 * directories or symbolic links, each name followed by a NUL byte. Fail
 * anything else with @ref GHOSTTY_DROP_ERROR_UNSUPPORTED. The terminal
 * only asks for files the drop's own `text/uri-list` named and what is
 * inside the directories among them, and never for a drop of the
 * program's own drag.
 *
 *
 * ## Offering Drags
 *
 *   1. The program enables offering drags, yielding
 *      @ref GHOSTTY_DRAG_EVENT_OFFERS. While it offers them, when the user
 *      starts the platform's drag gesture over the terminal (typically
 *      dragging with the left button held), report
 *      @ref GHOSTTY_DRAG_INPUT_GESTURE instead of handling it yourself.
 *   2. The program offers a drag and asks to start it, yielding
 *      @ref GHOSTTY_DRAG_EVENT_START with the offer. Copy what you need
 *      of it, start the native drag, and report the result with
 *      @ref GHOSTTY_DRAG_INPUT_START_RESULT.
 *   3. Report the drag's progress with @ref GHOSTTY_DRAG_INPUT_ACCEPTED,
 *      @ref GHOSTTY_DRAG_INPUT_OPERATION, and
 *      @ref GHOSTTY_DRAG_INPUT_DROPPED. When a drop target wants data
 *      that wasn't pre-sent, report @ref GHOSTTY_DRAG_INPUT_REQUEST_DATA;
 *      the program's reply arrives as @ref GHOSTTY_DRAG_EVENT_DATA events.
 *      @ref GHOSTTY_DRAG_EVENT_IMAGE changes the drag image and
 *      @ref GHOSTTY_DRAG_EVENT_CANCEL cancels the drag.
 *   4. Report @ref GHOSTTY_DRAG_INPUT_FINISHED, which ends the drag.
 *
 * @snippet c-vt-dnd/src/main.c dnd-drag
 *
 * ## Offering Drags from Remote Programs
 *
 * The files a program on another machine drags aren't here, so the
 * terminal fetches them for the drop target. With
 * @ref GHOSTTY_TERMINAL_OPT_DND_MACHINE_ID set, the offer of such a
 * program has `remote` set. When a drop target wants its `text/uri-list`,
 * report @ref GHOSTTY_DRAG_INPUT_REQUEST_DATA for it even though it was
 * pre-sent. The files it names then arrive as
 * @ref GHOSTTY_DRAG_EVENT_REMOTE_FILE events: write each under a
 * directory of your own at the relative path given, creating files
 * exclusively and without following symbolic links. A directory arrives
 * before its entries. Then the list arrives as
 * @ref GHOSTTY_DRAG_EVENT_DATA; give the drop target a copy rewritten to
 * name your copies, and keep it for later reads: the files are fetched
 * once, so requesting the list again answers GHOSTTY_NO_VALUE. Delete them at the next drag's start, when the drag
 * is canceled, or when the program stops offering drags, but not when
 * the drag finishes, since the drop target may still be reading them.
 *
 * @{
 */

/** Bit for the copy operation in an operations bitmask. */
#define GHOSTTY_DND_OPERATIONS_COPY 1u

/** Bit for the move operation in an operations bitmask. */
#define GHOSTTY_DND_OPERATIONS_MOVE 2u

/** A drag and drop operation. */
typedef enum GHOSTTY_ENUM_TYPED {
  GHOSTTY_DND_OPERATION_NONE = 0,
  GHOSTTY_DND_OPERATION_COPY = 1,
  GHOSTTY_DND_OPERATION_MOVE = 2,
  GHOSTTY_DND_OPERATION_MAX_VALUE = GHOSTTY_ENUM_MAX_VALUE,
} GhosttyDndOperation;

/**
 * A position on the terminal.
 *
 * This struct has a frozen layout and will not gain fields in future
 * versions.
 */
typedef struct {
  /** Grid cell column, zero-based from the left. */
  uint32_t cell_x;
  /** Grid cell row, zero-based from the top. */
  uint32_t cell_y;
  /** Pixels from the left of the terminal's content area. */
  int32_t pixel_x;
  /** Pixels from the top of the terminal's content area. */
  int32_t pixel_y;
} GhosttyDndPosition;

/* -------------------------------------------------------------------- */
/* Drops                                                                */
/* -------------------------------------------------------------------- */

/** The kind of a GhosttyDropEvent. */
typedef enum GHOSTTY_ENUM_TYPED {
  /** The program started or stopped accepting drops. */
  GHOSTTY_DROP_EVENT_REGISTRATION = 0,
  /** The program answered the drag over the terminal. */
  GHOSTTY_DROP_EVENT_ACCEPTANCE = 1,
  /** The program wants data from the drop. */
  GHOSTTY_DROP_EVENT_DATA_REQUEST = 2,
  /** The program is done with the drop. */
  GHOSTTY_DROP_EVENT_CONCLUDED = 3,
  GHOSTTY_DROP_EVENT_MAX_VALUE = GHOSTTY_ENUM_MAX_VALUE,
} GhosttyDropEventTag;

/** Value of @ref GHOSTTY_DROP_EVENT_REGISTRATION. */
typedef struct {
  /** Whether the program accepts drops. */
  bool accepting;
  /**
   * MIME types the program declared it accepts, usually none. Only
   * needed to register types with the OS ahead of a drag.
   */
  const GhosttyString* mimes;
  /** Number of entries in mimes. */
  size_t mimes_len;
} GhosttyDropRegistration;

/** Value of @ref GHOSTTY_DROP_EVENT_ACCEPTANCE. */
typedef struct {
  /** The operation the program would perform; none if it rejects the drag. */
  GhosttyDndOperation operation;
  /** The MIME types it wants, most preferred first. Empty if it didn't say. */
  const GhosttyString* mimes;
  /** Number of entries in mimes. */
  size_t mimes_len;
} GhosttyDropAcceptance;

/** Value of @ref GHOSTTY_DROP_EVENT_DATA_REQUEST. */
typedef struct {
  /**
   * Identifies the request when answering it. Never reused, so an answer
   * to a request the program abandoned is rejected rather than
   * answering another.
   */
  uint32_t id;
  /** Index into the MIME types given with @ref GHOSTTY_DROP_INPUT_DROP. */
  uint32_t mime_index;
  /** The MIME type to read from the native drop. Empty for a file request. */
  GhosttyString mime;
  /** Whether this is a file request, for a program on another machine. */
  bool has_path;
  /**
   * For a file request, the absolute path to read, without following
   * symbolic links. See "Accepting Drops from Remote Programs".
   */
  GhosttyString path;
} GhosttyDropDataRequest;

/** Value of a GhosttyDropEvent, selected by its tag. */
typedef union {
  /** @ref GHOSTTY_DROP_EVENT_REGISTRATION */
  GhosttyDropRegistration registration;
  /** @ref GHOSTTY_DROP_EVENT_ACCEPTANCE */
  GhosttyDropAcceptance acceptance;
  /** @ref GHOSTTY_DROP_EVENT_DATA_REQUEST */
  GhosttyDropDataRequest data_request;
  /** @ref GHOSTTY_DROP_EVENT_CONCLUDED: the operation the program performed. */
  GhosttyDndOperation concluded;
  /** Padding for ABI compatibility. Do not use. */
  uint64_t _padding[8];
} GhosttyDropEventValue;

/** A change in drops onto the terminal. */
typedef struct {
  GhosttyDropEventTag tag;
  GhosttyDropEventValue value;
} GhosttyDropEvent;

/**
 * Callback function type for the drop effect.
 *
 * @param terminal The terminal handle
 * @param userdata The userdata pointer set via GHOSTTY_TERMINAL_OPT_USERDATA
 * @param event What changed, borrowed for the duration of the call
 */
typedef void (*GhosttyTerminalDropFn)(GhosttyTerminal terminal,
                                      void* userdata,
                                      const GhosttyDropEvent* event);

/** The kind of a GhosttyDropInput. */
typedef enum GHOSTTY_ENUM_TYPED {
  /** A native drag entered or moved over the terminal. */
  GHOSTTY_DROP_INPUT_MOVE = 0,
  /** The native drag left the terminal without dropping. */
  GHOSTTY_DROP_INPUT_LEAVE = 1,
  /** The native drag dropped onto the terminal. */
  GHOSTTY_DROP_INPUT_DROP = 2,
  /** Some of the data for the data request being served. */
  GHOSTTY_DROP_INPUT_DATA = 3,
  /** The data request being served is complete. */
  GHOSTTY_DROP_INPUT_END = 4,
  /** The data request being served failed. */
  GHOSTTY_DROP_INPUT_FAIL = 5,
  /** What the file of the file request being served is, before its data. */
  GHOSTTY_DROP_INPUT_KIND = 6,
  GHOSTTY_DROP_INPUT_MAX_VALUE = GHOSTTY_ENUM_MAX_VALUE,
} GhosttyDropInputTag;

/** Value of @ref GHOSTTY_DROP_INPUT_MOVE and @ref GHOSTTY_DROP_INPUT_DROP. */
typedef struct {
  /** The pointer position. */
  GhosttyDndPosition position;
  /** The operations the drag allows, as GHOSTTY_DND_OPERATIONS_* bits. */
  uint32_t operations;
  /** The MIME types of the drag, which data requests index. */
  const GhosttyString* mimes;
  /** Number of entries in mimes. */
  size_t mimes_len;
} GhosttyDropMotion;

/** Value of @ref GHOSTTY_DROP_INPUT_DATA. */
typedef struct {
  /** The request's id. */
  uint32_t id;
  /** The data, sent as given so it can be passed on as the OS delivers it. */
  GhosttyString data;
} GhosttyDropData;

/** Why reading drop data failed. */
typedef enum GHOSTTY_ENUM_TYPED {
  GHOSTTY_DROP_ERROR_IO = 0,
  GHOSTTY_DROP_ERROR_NOT_FOUND = 1,
  GHOSTTY_DROP_ERROR_DENIED = 2,
  GHOSTTY_DROP_ERROR_TOO_LARGE = 3,
  GHOSTTY_DROP_ERROR_OUT_OF_MEMORY = 4,
  /** A file request named something other than a file, directory or symlink. */
  GHOSTTY_DROP_ERROR_UNSUPPORTED = 5,
  GHOSTTY_DROP_ERROR_MAX_VALUE = GHOSTTY_ENUM_MAX_VALUE,
} GhosttyDropError;

/** What a file entry in a drop is. Symbolic links are never followed. */
typedef enum GHOSTTY_ENUM_TYPED {
  /** A regular file; the data is its contents. */
  GHOSTTY_DROP_FILE_KIND_FILE = 0,
  /** A symbolic link; the data is its target. */
  GHOSTTY_DROP_FILE_KIND_SYMLINK = 1,
  /**
   * A directory; the data is the names of its entries that are regular
   * files, directories or symbolic links, each followed by a NUL byte.
   */
  GHOSTTY_DROP_FILE_KIND_DIRECTORY = 2,
  GHOSTTY_DROP_FILE_KIND_MAX_VALUE = GHOSTTY_ENUM_MAX_VALUE,
} GhosttyDropFileKind;

/**
 * Value of @ref GHOSTTY_DROP_INPUT_KIND. A file request not reported is a
 * regular file.
 */
typedef struct {
  /** The request's id. */
  uint32_t id;
  /** What the file is. */
  GhosttyDropFileKind kind;
} GhosttyDropEntryKind;

/** Value of @ref GHOSTTY_DROP_INPUT_FAIL. */
typedef struct {
  /** The request's id. */
  uint32_t id;
  /** Why it failed. */
  GhosttyDropError reason;
} GhosttyDropFailure;

/** Value of a GhosttyDropInput, selected by its tag. */
typedef union {
  /** @ref GHOSTTY_DROP_INPUT_MOVE */
  GhosttyDropMotion move;
  /** @ref GHOSTTY_DROP_INPUT_DROP */
  GhosttyDropMotion drop;
  /** @ref GHOSTTY_DROP_INPUT_DATA */
  GhosttyDropData data;
  /** @ref GHOSTTY_DROP_INPUT_END: the request's id. */
  uint32_t id;
  /** @ref GHOSTTY_DROP_INPUT_FAIL */
  GhosttyDropFailure fail;
  /** @ref GHOSTTY_DROP_INPUT_KIND */
  GhosttyDropEntryKind kind;
  /** Padding for ABI compatibility. Do not use. */
  uint64_t _padding[8];
} GhosttyDropInputValue;

/** Native drop activity. @ref GHOSTTY_DROP_INPUT_LEAVE has no value. */
typedef struct {
  GhosttyDropInputTag tag;
  GhosttyDropInputValue value;
} GhosttyDropInput;

/**
 * Report native drop activity to the program.
 *
 * Answering a data request with @ref GHOSTTY_DROP_INPUT_END or
 * @ref GHOSTTY_DROP_INPUT_FAIL delivers the next queued request, if any,
 * to the drop effect before returning. A drag arriving after a drop the
 * program never concluded delivers @ref GHOSTTY_DROP_EVENT_CONCLUDED with
 * no operation for that drop.
 *
 * @param terminal The terminal handle
 * @param input What happened
 * @return GHOSTTY_SUCCESS; GHOSTTY_NO_VALUE if the program isn't accepting
 *         drops; GHOSTTY_REJECTED if a request id isn't the request being
 *         served, or a kind is reported for a MIME request or after data; GHOSTTY_OUT_OF_MEMORY; or GHOSTTY_INVALID_VALUE for
 *         invalid arguments or no write_pty effect
 */
GHOSTTY_API GhosttyResult ghostty_terminal_drop(GhosttyTerminal terminal,
                                                const GhosttyDropInput* input);

/* -------------------------------------------------------------------- */
/* Drags                                                                */
/* -------------------------------------------------------------------- */

/** The kind of a GhosttyDragEvent. */
typedef enum GHOSTTY_ENUM_TYPED {
  /** The program started or stopped offering drags. */
  GHOSTTY_DRAG_EVENT_OFFERS = 0,
  /** The program asked to start the drag it offers. */
  GHOSTTY_DRAG_EVENT_START = 1,
  /** The program changed the image of the started drag. */
  GHOSTTY_DRAG_EVENT_IMAGE = 2,
  /** Requested drag data arrived or failed. */
  GHOSTTY_DRAG_EVENT_DATA = 3,
  /** The native drag in progress must be canceled. */
  GHOSTTY_DRAG_EVENT_CANCEL = 4,
  /** A file of a remote program's drag arrived. */
  GHOSTTY_DRAG_EVENT_REMOTE_FILE = 5,
  GHOSTTY_DRAG_EVENT_MAX_VALUE = GHOSTTY_ENUM_MAX_VALUE,
} GhosttyDragEventTag;

/** An offered MIME type. Frozen layout. */
typedef struct {
  /** The MIME type. */
  GhosttyString mime;
  /** Whether the program sent its data ahead of the drag. */
  bool has_pre_sent;
  /** The pre-sent data, when has_pre_sent. */
  GhosttyString pre_sent;
} GhosttyDragItem;

/** The format of a drag image. */
typedef enum GHOSTTY_ENUM_TYPED {
  /** 32-bit RGBA pixels. */
  GHOSTTY_DRAG_IMAGE_FORMAT_RGBA = 0,
  /** A PNG image, for the embedder to decode. */
  GHOSTTY_DRAG_IMAGE_FORMAT_PNG = 1,
  /** UTF-8 text for the embedder to render as the image. */
  GHOSTTY_DRAG_IMAGE_FORMAT_TEXT = 2,
  GHOSTTY_DRAG_IMAGE_FORMAT_MAX_VALUE = GHOSTTY_ENUM_MAX_VALUE,
} GhosttyDragImageFormat;

/** A drag image. Frozen layout. */
typedef struct {
  /** The image format. */
  GhosttyDragImageFormat format;
  /** Width in pixels, or for text the font scale numerator (0 meaning 1). */
  uint32_t width;
  /** Height in pixels, or for text the font scale denominator (0 meaning 1). */
  uint32_t height;
  /** Background opacity for text, 0 (transparent) to 1024 (opaque). */
  uint32_t opacity;
  /** The image data. */
  GhosttyString data;
} GhosttyDragImage;

/** Value of @ref GHOSTTY_DRAG_EVENT_START. */
typedef struct {
  /** The operations the drag allows, as GHOSTTY_DND_OPERATIONS_* bits. */
  uint32_t operations;
  /** The offered MIME types, in order. */
  const GhosttyDragItem* items;
  /** Number of entries in items. */
  size_t items_len;
  /** The drag's images, if any. */
  const GhosttyDragImage* images;
  /** Number of entries in images. */
  size_t images_len;
  /** Whether to show an image. */
  bool has_image;
  /** The index of the image to show, when has_image. */
  uint32_t image;
  /**
   * Whether the program is on another machine, so the files its
   * text/uri-list names are fetched. See "Offering Drags from Remote
   * Programs".
   */
  bool remote;
} GhosttyDragOffer;

/** Value of @ref GHOSTTY_DRAG_EVENT_IMAGE. */
typedef struct {
  /** Whether to show an image. */
  bool has_image;
  /** The index into the offer's images, when has_image. */
  uint32_t image;
} GhosttyDragImageChange;

/** The status of drag data received from the program. */
typedef enum GHOSTTY_ENUM_TYPED {
  /** More data may follow. */
  GHOSTTY_DRAG_DATA_STATUS_PENDING = 0,
  /** All data has been received. */
  GHOSTTY_DRAG_DATA_STATUS_COMPLETE = 1,
  /** The program failed to provide the data. */
  GHOSTTY_DRAG_DATA_STATUS_FAILED = 2,
  GHOSTTY_DRAG_DATA_STATUS_MAX_VALUE = GHOSTTY_ENUM_MAX_VALUE,
} GhosttyDragDataStatus;

/** Value of @ref GHOSTTY_DRAG_EVENT_DATA. */
typedef struct {
  /** Index into the offer's items. */
  uint32_t index;
  /** Data received since the last event for this item. */
  GhosttyString bytes;
  /** Whether more may follow, all has arrived, or it failed. */
  GhosttyDragDataStatus status;
} GhosttyDragData;

/** Value of @ref GHOSTTY_DRAG_EVENT_REMOTE_FILE. */
typedef struct {
  /** The index of the file in the text/uri-list, counting only its URIs. */
  uint32_t entry;
  /**
   * Where to write it, relative to your directory for the drag:
   * "<entry>/<name>" for the file the list names (create the "<entry>"
   * directory for it), with each directory level below it appended.
   * Names are sanitized.
   */
  GhosttyString path;
  /** What it is. */
  GhosttyDropFileKind kind;
  /**
   * A file's data since its last event, or a symbolic link's target.
   * Empty for a directory.
   */
  GhosttyString bytes;
  /** Complete once the file is. */
  GhosttyDragDataStatus status;
} GhosttyDragRemoteFile;

/** Value of a GhosttyDragEvent, selected by its tag. */
typedef union {
  /** @ref GHOSTTY_DRAG_EVENT_OFFERS: whether the program offers drags. */
  bool enabled;
  /** @ref GHOSTTY_DRAG_EVENT_START */
  GhosttyDragOffer start;
  /** @ref GHOSTTY_DRAG_EVENT_IMAGE */
  GhosttyDragImageChange image;
  /** @ref GHOSTTY_DRAG_EVENT_DATA */
  GhosttyDragData data;
  /** @ref GHOSTTY_DRAG_EVENT_REMOTE_FILE */
  GhosttyDragRemoteFile remote_file;
  /** Padding for ABI compatibility. Do not use. */
  uint64_t _padding[8];
} GhosttyDragEventValue;

/** A change in the drag the program offers. @ref GHOSTTY_DRAG_EVENT_CANCEL has no value. */
typedef struct {
  GhosttyDragEventTag tag;
  GhosttyDragEventValue value;
} GhosttyDragEvent;

/**
 * Callback function type for the drag effect.
 *
 * @param terminal The terminal handle
 * @param userdata The userdata pointer set via GHOSTTY_TERMINAL_OPT_USERDATA
 * @param event What changed, borrowed for the duration of the call
 */
typedef void (*GhosttyTerminalDragFn)(GhosttyTerminal terminal,
                                      void* userdata,
                                      const GhosttyDragEvent* event);

/** The kind of a GhosttyDragInput. */
typedef enum GHOSTTY_ENUM_TYPED {
  /** The user started the platform's drag gesture over the terminal. */
  GHOSTTY_DRAG_INPUT_GESTURE = 0,
  /** The result of starting the native drag the program asked for. */
  GHOSTTY_DRAG_INPUT_START_RESULT = 1,
  /** A drop target accepted the drag. */
  GHOSTTY_DRAG_INPUT_ACCEPTED = 2,
  /** The operation the drag would perform changed. */
  GHOSTTY_DRAG_INPUT_OPERATION = 3,
  /** The drag was dropped onto a target. */
  GHOSTTY_DRAG_INPUT_DROPPED = 4,
  /** The drag finished, which ends it. */
  GHOSTTY_DRAG_INPUT_FINISHED = 5,
  /** A drop target wants data that wasn't pre-sent. */
  GHOSTTY_DRAG_INPUT_REQUEST_DATA = 6,
  GHOSTTY_DRAG_INPUT_MAX_VALUE = GHOSTTY_ENUM_MAX_VALUE,
} GhosttyDragInputTag;

/** The result of starting a native drag. */
typedef enum GHOSTTY_ENUM_TYPED {
  /** The native drag started. Its pre-sent data and images are freed. */
  GHOSTTY_DRAG_START_STARTED = 0,
  /** The user already let go of the drag. */
  GHOSTTY_DRAG_START_DENIED = 1,
  /** The native drag couldn't be started. */
  GHOSTTY_DRAG_START_FAILED = 2,
  GHOSTTY_DRAG_START_MAX_VALUE = GHOSTTY_ENUM_MAX_VALUE,
} GhosttyDragStartResult;

/** Value of a GhosttyDragInput, selected by its tag. */
typedef union {
  /** @ref GHOSTTY_DRAG_INPUT_GESTURE: where the gesture started. */
  GhosttyDndPosition position;
  /** @ref GHOSTTY_DRAG_INPUT_START_RESULT */
  GhosttyDragStartResult start_result;
  /**
   * @ref GHOSTTY_DRAG_INPUT_ACCEPTED: the index of the offered MIME type
   * the target prefers, or -1 if unknown.
   */
  int32_t mime_index;
  /** @ref GHOSTTY_DRAG_INPUT_OPERATION */
  GhosttyDndOperation operation;
  /** @ref GHOSTTY_DRAG_INPUT_FINISHED: whether the drag was canceled. */
  bool canceled;
  /** @ref GHOSTTY_DRAG_INPUT_REQUEST_DATA: the index of the offered MIME type. */
  uint32_t index;
  /** Padding for ABI compatibility. Do not use. */
  uint64_t _padding[8];
} GhosttyDragInputValue;

/** Native drag activity. @ref GHOSTTY_DRAG_INPUT_DROPPED has no value. */
typedef struct {
  GhosttyDragInputTag tag;
  GhosttyDragInputValue value;
} GhosttyDragInput;

/**
 * Report native drag activity to the program. Progress reports are
 * ignored unless the drag started.
 *
 * @param terminal The terminal handle
 * @param input What happened
 * @return GHOSTTY_SUCCESS; GHOSTTY_NO_VALUE if the program doesn't offer
 *         drags, or no drag is in progress or the index is out of range
 *         for @ref GHOSTTY_DRAG_INPUT_REQUEST_DATA; GHOSTTY_REJECTED for a
 *         start result when no start was asked for; or
 *         GHOSTTY_INVALID_VALUE for invalid arguments or no write_pty
 *         effect
 */
GHOSTTY_API GhosttyResult ghostty_terminal_drag(GhosttyTerminal terminal,
                                                const GhosttyDragInput* input);

/** @} */

#ifdef __cplusplus
}
#endif

#endif /* GHOSTTY_VT_DND_H */
