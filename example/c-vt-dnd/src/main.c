#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <ghostty/vt.h>

#define GS(s) ((GhosttyString){.ptr = (const uint8_t*)(s), .len = sizeof(s) - 1})

// Whether a program accepts drops, as the drop effect last said.
static bool accepting_drops = false;

// Print bytes destined for the pty with control characters made visible.
static void print_escaped(const uint8_t* data, size_t len) {
  for (size_t i = 0; i < len; i++) {
    if (data[i] == 0x1b) printf("ESC");
    else putchar(data[i]);
  }
}

// Everything the terminal writes to the running program.
static void on_write_pty(GhosttyTerminal terminal,
                         void* userdata,
                         const uint8_t* data,
                         size_t len) {
  (void)terminal;
  (void)userdata;
  printf("  -> pty: ");
  print_escaped(data, len);
  printf("\n");
}

//! [dnd-drop]
// The data of the native drop, as an embedder would read it from the
// OS drop session.
static const char* native_drop_data(GhosttyString mime) {
  if (mime.len == 10 && memcmp(mime.ptr, "text/plain", 10) == 0)
    return "hello from the drop";
  return NULL;
}

// Serve one of the program's drop data requests. This answers
// synchronously; an embedder reading from an OS drop asynchronously
// answers later the same way. Answering delivers the next request, if
// any, to the drop effect.
static void serve_drop_request(GhosttyTerminal terminal,
                               const GhosttyDropDataRequest* req) {
  printf("  serving request %u for %.*s\n", req->id, (int)req->mime.len,
         (const char*)req->mime.ptr);
  const char* data = native_drop_data(req->mime);
  if (data == NULL) {
    GhosttyDropInput fail = {.tag = GHOSTTY_DROP_INPUT_FAIL};
    fail.value.fail.id = req->id;
    fail.value.fail.reason = GHOSTTY_DROP_ERROR_NOT_FOUND;
    ghostty_terminal_drop(terminal, &fail);
    return;
  }

  GhosttyDropInput input = {.tag = GHOSTTY_DROP_INPUT_DATA};
  input.value.data.id = req->id;
  input.value.data.data =
      (GhosttyString){.ptr = (const uint8_t*)data, .len = strlen(data)};
  ghostty_terminal_drop(terminal, &input);

  GhosttyDropInput end = {.tag = GHOSTTY_DROP_INPUT_END};
  end.value.id = req->id;
  ghostty_terminal_drop(terminal, &end);
}

// Report a native drag moving over the terminal, or dropping, to the
// program accepting drops.
static void native_drag(GhosttyTerminal terminal, bool drop) {
  if (!accepting_drops) {
    printf("  no program accepts drops; handle the drag natively\n");
    return;
  }

  GhosttyString mimes[] = {GS("text/plain"), GS("text/uri-list")};
  GhosttyDropInput input = {
      .tag = drop ? GHOSTTY_DROP_INPUT_DROP : GHOSTTY_DROP_INPUT_MOVE,
  };
  GhosttyDropMotion* motion = drop ? &input.value.drop : &input.value.move;
  motion->position = (GhosttyDndPosition){
      .cell_x = 4, .cell_y = 2, .pixel_x = 40, .pixel_y = 36};
  motion->operations = GHOSTTY_DND_OPERATIONS_COPY;
  motion->mimes = mimes;
  motion->mimes_len = 2;
  ghostty_terminal_drop(terminal, &input);
}

// The drop effect: what the program changed.
static void on_drop(GhosttyTerminal terminal,
                    void* userdata,
                    const GhosttyDropEvent* event) {
  (void)userdata;
  switch (event->tag) {
  case GHOSTTY_DROP_EVENT_REGISTRATION:
    accepting_drops = event->value.registration.accepting;
    printf("  drop event: registration (accepting %d)\n", accepting_drops);
    break;
  case GHOSTTY_DROP_EVENT_ACCEPTANCE:
    printf("  drop event: acceptance (operation %d)\n",
           (int)event->value.acceptance.operation);
    break;
  case GHOSTTY_DROP_EVENT_DATA_REQUEST:
    printf("  drop event: data request\n");
    serve_drop_request(terminal, &event->value.data_request);
    break;
  case GHOSTTY_DROP_EVENT_CONCLUDED:
    printf("  drop event: concluded with operation %d, finish the native "
           "drop\n",
           (int)event->value.concluded);
    break;
  default:
    break;
  }
}
//! [dnd-drop]

//! [dnd-drag]
// Start the native drag the program asked for, copying what the OS drag
// session needs from the offer first.
static void start_drag(GhosttyTerminal terminal, const GhosttyDragOffer* offer) {
  for (size_t i = 0; i < offer->items_len; i++) {
    const GhosttyDragItem* item = &offer->items[i];
    printf("  offered %.*s", (int)item->mime.len, (const char*)item->mime.ptr);
    if (item->has_pre_sent)
      printf(" with \"%.*s\"", (int)item->pre_sent.len,
             (const char*)item->pre_sent.ptr);
    printf("\n");
  }

  // A real embedder starts the OS drag here and reports
  // GHOSTTY_DRAG_START_DENIED if the user already released the button.
  GhosttyDragInput input = {.tag = GHOSTTY_DRAG_INPUT_START_RESULT};
  input.value.start_result = GHOSTTY_DRAG_START_STARTED;
  ghostty_terminal_drag(terminal, &input);
}

// The drag effect: what the program changed.
static void on_drag(GhosttyTerminal terminal,
                    void* userdata,
                    const GhosttyDragEvent* event) {
  (void)userdata;
  switch (event->tag) {
  case GHOSTTY_DRAG_EVENT_OFFERS:
    printf("  drag event: offers (enabled %d)\n", event->value.enabled);
    break;
  case GHOSTTY_DRAG_EVENT_START:
    printf("  drag event: start\n");
    start_drag(terminal, &event->value.start);
    break;
  case GHOSTTY_DRAG_EVENT_CANCEL:
    printf("  drag event: cancel\n");
    break;
  default:
    printf("  drag event: %d\n", (int)event->tag);
    break;
  }
}
//! [dnd-drag]

static void vt_write(GhosttyTerminal terminal, const char* seq) {
  ghostty_terminal_vt_write(terminal, (const uint8_t*)seq, strlen(seq));
}

int main() {
  GhosttyTerminal terminal = NULL;
  if (ghostty_terminal_new(NULL, &terminal, 80, 24) != GHOSTTY_SUCCESS) {
    fprintf(stderr, "Failed to create terminal\n");
    return 1;
  }

  // Setting the drop and drag effects enables each direction.
  ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_WRITE_PTY,
                       (const void*)on_write_pty);
  ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_DROP,
                       (const void*)on_drop);
  ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_DRAG,
                       (const void*)on_drag);

  printf("A drag before any program accepts drops:\n");
  native_drag(terminal, false);

  printf("The program registers to accept drops:\n");
  vt_write(terminal, "\x1b]72;t=a\x1b\\");

  printf("A native drag moves over the terminal:\n");
  native_drag(terminal, false);

  printf("The program accepts a copy of text:\n");
  vt_write(terminal, "\x1b]72;t=m:o=1;text/plain\x1b\\");

  printf("The drag drops and the program requests the text:\n");
  native_drag(terminal, true);
  vt_write(terminal, "\x1b]72;t=r:x=1\x1b\\");

  printf("The program concludes the drop:\n");
  vt_write(terminal, "\x1b]72;t=r:o=1\x1b\\");

  printf("The program enables offering drags:\n");
  vt_write(terminal, "\x1b]72;t=o:x=1\x1b\\");

  printf("The user drags over the terminal:\n");
  GhosttyDragInput gesture = {.tag = GHOSTTY_DRAG_INPUT_GESTURE};
  gesture.value.position = (GhosttyDndPosition){
      .cell_x = 1, .cell_y = 1, .pixel_x = 12, .pixel_y = 20};
  ghostty_terminal_drag(terminal, &gesture);

  printf("The program offers text and starts the drag:\n");
  vt_write(terminal, "\x1b]72;t=o:o=1;text/plain\x1b\\");
  vt_write(terminal, "\x1b]72;t=p:x=0;ZHJhZ2dlZCB0ZXh0\x1b\\");
  vt_write(terminal, "\x1b]72;t=P:x=-1\x1b\\");

  printf("The drag is dropped and finishes:\n");
  GhosttyDragInput dropped = {.tag = GHOSTTY_DRAG_INPUT_DROPPED};
  ghostty_terminal_drag(terminal, &dropped);
  GhosttyDragInput finished = {.tag = GHOSTTY_DRAG_INPUT_FINISHED};
  finished.value.canceled = false;
  ghostty_terminal_drag(terminal, &finished);

  ghostty_terminal_free(terminal);
  return 0;
}
