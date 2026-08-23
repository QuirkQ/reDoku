/* mrbgems/mruby-rm2/src/input.c
 *
 * evdev input for rm2fb clients. The fd itself comes from the display
 * server over the display connection (Display#open_input, PLAN.md §3
 * tag 4) so that a client keeps to its one allowed socket per PID; this
 * file only decodes and polls it.
 *
 * evdev is a stateful stream: each SYN_REPORT ends a packet whose fields
 * carry over from the previous one, so we keep the sticky axis/tool state
 * here and emit one sample per SYN_REPORT.
 *
 * Two kinds of node are decoded, into the same [x, y, pressure, tools]
 * sample: the pen digitizer (ABS_X/ABS_Y/ABS_PRESSURE with BTN_TOOL_PEN,
 * BTN_TOOL_RUBBER, BTN_TOUCH) and the multitouch screen (ABS_MT_*, folded
 * down to a single contact — see apply_mt_event). A sample does not say
 * which node it came from and must not be asked to: the packet that ends a
 * stroke has every tool bit clear on either device, so the two are
 * indistinguishable at exactly the moment it would matter. A caller that
 * needs to tell them apart keeps the inputs apart — it opened them by name
 * and knows which is which.
 *
 * Two lifecycle rules a caller has to know about:
 *
 *  - The fd is always non-blocking, whatever open flags were asked for:
 *    pending_events drains until EAGAIN, and a blocking fd would stall the
 *    whole VM on a quiet device. rm2_input_new enforces it.
 *
 *  - An input can hang up while still being open. The kernel raises
 *    POLLHUP/POLLERR on an evdev node whose device goes away — which is
 *    what happens when rm2fb restarts and tears down the uinput clones it
 *    publishes — and read() then reports EOF. Both `wait` and
 *    `pending_events` notice and set #hung_up?. A hung-up input never
 *    reports readable again, so a caller must close it and drop it from
 *    its source list; #closed? stays false, because the fd is still ours.
 */
#include "rm2.h"

#include <mruby/array.h>
#include <mruby/data.h>
#include <mruby/error.h>

#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <linux/input.h>
#include <poll.h>
#include <stdint.h>
#include <unistd.h>

#define RM2_MAX_WAIT 8       /* pollfds accepted by RM2::Input.wait */
#define RM2_READ_EVENTS 64   /* events per read() */

/* RM2::Input tool bits, as reported in a sample's `tools` field.
 *
 * TOUCH is evdev's BTN_TOUCH: the PEN TIP pressed against the glass. It has
 * never meant a finger, and adding the touchscreen did not change that —
 * a finger is FINGER, from the multitouch axes of a different device. */
enum {
  RM2_TOOL_PEN = 1,
  RM2_TOOL_RUBBER = 2,
  RM2_TOOL_TOUCH = 4,
  RM2_TOOL_FINGER = 8
};

typedef struct {
  int fd;
  int hung_up;                   /* POLLHUP/POLLERR/POLLNVAL, or read() EOF */
  int resync;                    /* inside a packet torn by SYN_DROPPED */
  int32_t x, y, pressure, tools; /* sticky evdev state */
  int32_t mt_slot;               /* ABS_MT_SLOT: whose MT events follow */
  int32_t mt_contact;            /* the slot we follow, -1 when none is down */
} rm2_input;

static void
rm2_input_dfree(mrb_state* mrb, void* p) {
  rm2_input* in = (rm2_input*)p;
  if (in == NULL) return;
  if (in->fd >= 0) close(in->fd);
  mrb_free(mrb, in);
}

static const struct mrb_data_type rm2_input_type = { "RM2::Input",
                                                     rm2_input_dfree };

static rm2_input*
get_open_input(mrb_state* mrb, mrb_value self) {
  rm2_input* in = DATA_GET_PTR(mrb, self, &rm2_input_type, rm2_input);
  if (in == NULL || in->fd < 0)
    mrb_raise(mrb, E_RUNTIME_ERROR, "input is closed");
  return in;
}

mrb_value
rm2_input_new(mrb_state* mrb, int fd) {
  struct RClass* cls =
    mrb_class_get_under(mrb, mrb_module_get(mrb, "RM2"), "Input");
  rm2_input* in;
  int fl;

  /* Non-blocking is an invariant of this object, not a property of the
   * flags the caller passed to Display#open_input: pending_events drains
   * until EAGAIN, so a blocking fd would park the VM inside read().
   *
   * F_GETFL first, though: those flags went over the wire and the server
   * opened the node with them, so a bare F_SETFL would clear every status
   * flag but this one — silently discarding what Display#open_input
   * advertises it accepts. Add the invariant, do not replace the word. */
  fl = fcntl(fd, F_GETFL);
  if (fl < 0 || fcntl(fd, F_SETFL, fl | O_NONBLOCK) < 0) {
    int e = errno;
    close(fd);
    errno = e;
    mrb_sys_fail(mrb, "set input device non-blocking");
  }

  in = (rm2_input*)mrb_malloc(mrb, sizeof(rm2_input));
  in->fd = fd;
  in->hung_up = 0;
  in->resync = 0;
  in->x = 0;
  in->y = 0;
  in->pressure = 0;
  in->tools = 0;
  in->mt_slot = 0;    /* evdev's slot 0 is current until ABS_MT_SLOT says so */
  in->mt_contact = -1;
  return mrb_obj_value(mrb_data_object_alloc(mrb, cls, in, &rm2_input_type));
}

/* Multitouch, evdev protocol B, folded down to ONE contact.
 *
 * A packet from the touchscreen selects a slot with ABS_MT_SLOT, then
 * reports that slot's ABS_MT_TRACKING_ID — non-negative while the contact
 * exists, -1 when it ends — and its ABS_MT_POSITION_X/_Y. Slot and id are
 * sticky, exactly like the pen's axes.
 *
 * Only the first contact to arrive is followed, and a per-slot table is
 * deliberately not kept: the touchscreen is here so that three 400x140
 * buttons can be tapped with a finger, and a button needs one point and a
 * down/up edge. A second finger has nothing to add, so a contact beginning
 * while another is already down is ignored until it lifts and presses
 * again. Real gestures would need the table; nothing in reDoku wants one.
 *
 * The contact lands in the same x/y fields a pen sample uses, and its
 * presence in the FINGER bit — never TOUCH, which is BTN_TOUCH and belongs
 * to the pen tip. */
static void
apply_mt_event(rm2_input* in, const struct input_event* ev) {
  switch (ev->code) {
    case ABS_MT_SLOT:
      in->mt_slot = ev->value;
      break;
    case ABS_MT_TRACKING_ID:
      if (ev->value >= 0) {
        if (in->mt_contact < 0) {
          in->mt_contact = in->mt_slot;
          in->tools |= RM2_TOOL_FINGER;
        }
      }
      else if (in->mt_slot == in->mt_contact) {
        in->mt_contact = -1;
        in->tools &= ~RM2_TOOL_FINGER;
      }
      break;
    /* The driver reports a new contact's slot state before its position
     * (input_mt_report_slot_state, then input_report_abs), so by the time
     * these arrive mt_contact already names the slot they belong to. Events
     * for any other slot are dropped here, which is what keeps a second
     * finger from moving the followed contact's point.
     *
     * The price of having no per-slot table: the kernel de-duplicates
     * ABS_MT_POSITION_* per slot, so if a fresh contact lands on a slot
     * whose stored coordinate already equals its own, no position event is
     * emitted and x/y still hold the PREVIOUS followed contact's point —
     * the first sample of that contact then reports where the last finger
     * was. It needs an exact-pixel coincidence on a slot reuse, so it is
     * close to unreachable, and the benign corner is checked: at process
     * start x/y are 0, which maps to screen (0, 1871), outside all three
     * button rects. Fixing it properly means the table, and nothing in
     * reDoku wants one. */
    case ABS_MT_POSITION_X:
      if (in->mt_slot == in->mt_contact) in->x = ev->value;
      break;
    case ABS_MT_POSITION_Y:
      if (in->mt_slot == in->mt_contact) in->y = ev->value;
      break;
    default:
      break;
  }
}

/* Folds one event into the sticky state. Returns 1 at a packet boundary
 * whose state is coherent enough to report as a sample. */
static int
apply_event(rm2_input* in, const struct input_event* ev) {
  switch (ev->type) {
    case EV_SYN:
      if (ev->code == SYN_DROPPED) {
        /* The kernel's buffer overflowed and it discarded events, so this
         * packet is torn: the sticky state now mixes pre- and post-drop
         * values. Keep folding, but report nothing until a SYN_REPORT has
         * closed the torn packet. Reachable here — a full-screen GC16
         * refresh takes about a second, long enough for the pen to
         * overrun the buffer. */
        in->resync = 1;
        return 0;
      }
      if (ev->code != SYN_REPORT) return 0;
      if (in->resync) {
        in->resync = 0; /* the torn packet ends here, unreported */
        return 0;
      }
      return 1;
    case EV_ABS:
      if (ev->code == ABS_X) in->x = ev->value;
      else if (ev->code == ABS_Y) in->y = ev->value;
      else if (ev->code == ABS_PRESSURE) in->pressure = ev->value;
      else apply_mt_event(in, ev);
      return 0;
    case EV_KEY: {
      int bit = 0;
      if (ev->code == BTN_TOOL_PEN) bit = RM2_TOOL_PEN;
      else if (ev->code == BTN_TOOL_RUBBER) bit = RM2_TOOL_RUBBER;
      else if (ev->code == BTN_TOUCH) bit = RM2_TOOL_TOUCH;
      if (bit != 0) {
        if (ev->value != 0) in->tools |= bit;
        else in->tools &= ~bit;
      }
      return 0;
    }
    default:
      return 0;
  }
}

static mrb_value
rm2_input_pending_events(mrb_state* mrb, mrb_value self) {
  rm2_input* in = get_open_input(mrb, self);
  struct input_event evs[RM2_READ_EVENTS];
  mrb_value out = mrb_ary_new(mrb);
  int ai = mrb_gc_arena_save(mrb);

  for (;;) {
    ssize_t n = read(in->fd, evs, sizeof(evs));
    size_t count, i;

    if (n < 0) {
      if (errno == EINTR) continue;
      if (errno == EAGAIN || errno == EWOULDBLOCK) break;
      mrb_sys_fail(mrb, "read input device");
    }
    if (n == 0) {
      /* EOF on an evdev fd means the device is gone for good, not that it
       * is momentarily quiet — a quiet device gives EAGAIN. Report what we
       * already decoded and let the caller see #hung_up?. */
      in->hung_up = 1;
      break;
    }
    /* evdev hands back whole events or fails with EINVAL, so a partial
     * event is not a short read to be resumed: it means this fd is not an
     * evdev node, or was opened against a different ABI. Loosening this
     * check would silently misalign every event that follows. */
    if ((size_t)n % sizeof(struct input_event) != 0)
      mrb_raise(mrb, E_RUNTIME_ERROR, "short read from input device");

    count = (size_t)n / sizeof(struct input_event);
    for (i = 0; i < count; i++) {
      if (!apply_event(in, &evs[i])) continue;
      mrb_value s = mrb_ary_new_capa(mrb, 4);
      mrb_ary_push(mrb, s, mrb_int_value(mrb, in->x));
      mrb_ary_push(mrb, s, mrb_int_value(mrb, in->y));
      mrb_ary_push(mrb, s, mrb_int_value(mrb, in->pressure));
      mrb_ary_push(mrb, s, mrb_int_value(mrb, in->tools));
      mrb_ary_push(mrb, out, s);
      mrb_gc_arena_restore(mrb, ai);
      mrb_gc_protect(mrb, out);
    }
    if (count < RM2_READ_EVENTS) break; /* drained this pass */
  }
  return out;
}

static mrb_value
rm2_input_fd(mrb_state* mrb, mrb_value self) {
  return mrb_int_value(mrb, get_open_input(mrb, self)->fd);
}

static mrb_value
rm2_input_close(mrb_state* mrb, mrb_value self) {
  rm2_input* in = DATA_GET_PTR(mrb, self, &rm2_input_type, rm2_input);
  if (in != NULL && in->fd >= 0) {
    close(in->fd);
    in->fd = -1;
  }
  return mrb_nil_value();
}

static mrb_value
rm2_input_closed_p(mrb_state* mrb, mrb_value self) {
  rm2_input* in = DATA_GET_PTR(mrb, self, &rm2_input_type, rm2_input);
  return mrb_bool_value(in == NULL || in->fd < 0);
}

/* Deliberately not folded into #closed?: the fd is still open and still
 * ours to close, but it will never report events again. */
static mrb_value
rm2_input_hung_up_p(mrb_state* mrb, mrb_value self) {
  rm2_input* in = DATA_GET_PTR(mrb, self, &rm2_input_type, rm2_input);
  return mrb_bool_value(in != NULL && in->hung_up != 0);
}

/* RM2::Input.wait(inputs, timeout_ms) -> true if any input has events.
 * A signal (SIGTERM, SIGCONT) returns false rather than restarting the
 * poll, so the caller's loop gets a turn to notice its flags.
 *
 * Always takes at least as long as it is given when nothing can be ready:
 * a hung-up fd raises POLLHUP on every poll and makes poll return at once,
 * so polling one would hand the caller a busy-spin the moment its last live
 * source died. Hung-up inputs are left out of the pollfd set, and with none
 * left this waits on no fds at all — which is exactly a sleep. */
static mrb_value
rm2_input_s_wait(mrb_state* mrb, mrb_value klass) {
  mrb_value ary;
  mrb_int timeout;
  struct pollfd pfds[RM2_MAX_WAIT];
  rm2_input* ins[RM2_MAX_WAIT];
  mrb_int len, i, nfds;
  int n, ready;

  mrb_get_args(mrb, "Ai", &ary, &timeout);
  len = RARRAY_LEN(ary);
  /* %i consumes an mrb_int and %d a plain int (mruby 4.0's mrb_vformat, in
   * its src/error.c) — they are not interchangeable, and an mrb_int passed
   * to %d is a varargs type mismatch wherever the two differ in width, as
   * they do on the host. Hence %i here, and hence the casts. */
  if (len > RM2_MAX_WAIT)
    mrb_raisef(mrb, E_ARGUMENT_ERROR, "at most %i inputs, got %i",
               (mrb_int)RM2_MAX_WAIT, len);
  /* poll reads a negative timeout as "block forever". Reaching that by
   * arithmetic would hang the game loop with no diagnostic, so say no. */
  if (timeout < 0)
    mrb_raise(mrb, E_ARGUMENT_ERROR, "timeout must be >= 0 milliseconds");

  /* Every element is still type-checked and still has to be open, whether
   * or not it ends up in the poll set: a closed input is a caller bug and
   * must say so on the turn it happens, not silently do nothing. */
  nfds = 0;
  for (i = 0; i < len; i++) {
    mrb_value v = mrb_ary_ref(mrb, ary, i);
    rm2_input* in;
    if (!mrb_obj_is_kind_of(mrb, v, mrb_class_ptr(klass)))
      mrb_raise(mrb, E_TYPE_ERROR, "not an RM2::Input");
    in = get_open_input(mrb, v);
    if (in->hung_up) continue; /* never readable again; see the header */
    ins[nfds] = in;
    pfds[nfds].fd = in->fd;
    pfds[nfds].events = POLLIN;
    pfds[nfds].revents = 0;
    nfds++;
  }

  /* poll(NULL, 0, ms) is a portable sleep, and it is what an empty list or
   * an all-hung-up one gets: nothing to watch, but the caller's loop still
   * has to be paced or it spins at 100% CPU on a battery device. */
  n = poll(nfds == 0 ? NULL : pfds, (nfds_t)nfds,
           timeout > (mrb_int)INT_MAX ? INT_MAX : (int)timeout);
  if (n < 0) {
    if (errno == EINTR) return mrb_false_value();
    mrb_sys_fail(mrb, "poll input devices");
  }

  /* POLLHUP, POLLERR and POLLNVAL arrive whether or not they were asked
   * for, and each of them makes poll return a positive count. Reporting a
   * bare `n > 0` as "events pending" would call a dead fd readable for
   * ever while pending_events returned nothing: only POLLIN is data. */
  ready = 0;
  for (i = 0; i < nfds; i++) {
    if ((pfds[i].revents & (POLLHUP | POLLERR | POLLNVAL)) != 0)
      ins[i]->hung_up = 1;
    if ((pfds[i].revents & POLLIN) != 0) ready = 1;
  }
  return mrb_bool_value(ready != 0);
}

void
rm2_input_init(mrb_state* mrb, struct RClass* rm2) {
  struct RClass* cls =
    mrb_define_class_under(mrb, rm2, "Input", mrb->object_class);
  MRB_SET_INSTANCE_TT(cls, MRB_TT_CDATA);
  /* Only Display#open_input can make one: the fd comes from the server. */
  mrb_undef_class_method(mrb, cls, "new");
  mrb_define_class_method(mrb, cls, "wait", rm2_input_s_wait,
                          MRB_ARGS_REQ(2));
  mrb_define_method(mrb, cls, "pending_events", rm2_input_pending_events,
                    MRB_ARGS_NONE());
  mrb_define_method(mrb, cls, "fd", rm2_input_fd, MRB_ARGS_NONE());
  mrb_define_method(mrb, cls, "close", rm2_input_close, MRB_ARGS_NONE());
  mrb_define_method(mrb, cls, "closed?", rm2_input_closed_p, MRB_ARGS_NONE());
  mrb_define_method(mrb, cls, "hung_up?", rm2_input_hung_up_p, MRB_ARGS_NONE());

  mrb_define_const(mrb, cls, "PEN", mrb_int_value(mrb, RM2_TOOL_PEN));
  mrb_define_const(mrb, cls, "RUBBER", mrb_int_value(mrb, RM2_TOOL_RUBBER));
  /* BTN_TOUCH — the pen tip on the glass. A finger is FINGER, below. */
  mrb_define_const(mrb, cls, "TOUCH", mrb_int_value(mrb, RM2_TOOL_TOUCH));
  mrb_define_const(mrb, cls, "FINGER", mrb_int_value(mrb, RM2_TOOL_FINGER));
  mrb_define_const(mrb, cls, "MAX_WAIT", mrb_int_value(mrb, RM2_MAX_WAIT));
  mrb_define_const(mrb, cls, "NONBLOCK", mrb_int_value(mrb, O_NONBLOCK));
  mrb_define_const(mrb, cls, "EVENT_SIZE",
                   mrb_int_value(mrb, (mrb_int)sizeof(struct input_event)));
}
