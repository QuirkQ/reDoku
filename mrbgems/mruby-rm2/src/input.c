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
 */
#include "rm2.h"

#include <mruby/array.h>
#include <mruby/data.h>
#include <mruby/error.h>

#include <errno.h>
#include <fcntl.h>
#include <linux/input.h>
#include <poll.h>
#include <stdint.h>
#include <string.h>
#include <unistd.h>

#define RM2_MAX_WAIT 8       /* pollfds accepted by RM2::Input.wait */
#define RM2_READ_EVENTS 64   /* events per read() */

/* RM2::Input tool bits, as reported in a sample's `tools` field. */
enum { RM2_TOOL_PEN = 1, RM2_TOOL_RUBBER = 2, RM2_TOOL_TOUCH = 4 };

typedef struct {
  int fd;
  int32_t x, y, pressure, tools; /* sticky evdev state */
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
  rm2_input* in = (rm2_input*)mrb_malloc(mrb, sizeof(rm2_input));

  in->fd = fd;
  in->x = 0;
  in->y = 0;
  in->pressure = 0;
  in->tools = 0;
  return mrb_obj_value(mrb_data_object_alloc(mrb, cls, in, &rm2_input_type));
}

/* Folds one event into the sticky state. Returns 1 at a packet boundary. */
static int
apply_event(rm2_input* in, const struct input_event* ev) {
  switch (ev->type) {
    case EV_SYN:
      return ev->code == SYN_REPORT;
    case EV_ABS:
      if (ev->code == ABS_X) in->x = ev->value;
      else if (ev->code == ABS_Y) in->y = ev->value;
      else if (ev->code == ABS_PRESSURE) in->pressure = ev->value;
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
    if (n == 0) break; /* EOF: no writer, nothing pending */
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

/* RM2::Input.wait(inputs, timeout_ms) -> true if any input has events.
 * A signal (SIGTERM, SIGCONT) returns false rather than restarting the
 * poll, so the caller's loop gets a turn to notice its flags. */
static mrb_value
rm2_input_s_wait(mrb_state* mrb, mrb_value klass) {
  mrb_value ary;
  mrb_int timeout;
  struct pollfd pfds[RM2_MAX_WAIT];
  mrb_int len, i;
  int n;

  mrb_get_args(mrb, "Ai", &ary, &timeout);
  len = RARRAY_LEN(ary);
  /* Both %d and %i consume an mrb_int, so the literal must be cast. */
  if (len > RM2_MAX_WAIT)
    mrb_raisef(mrb, E_ARGUMENT_ERROR, "at most %i inputs, got %i",
               (mrb_int)RM2_MAX_WAIT, len);
  if (len == 0) return mrb_false_value();

  for (i = 0; i < len; i++) {
    mrb_value v = mrb_ary_ref(mrb, ary, i);
    rm2_input* in;
    if (!mrb_obj_is_kind_of(mrb, v, mrb_class_ptr(klass)))
      mrb_raise(mrb, E_TYPE_ERROR, "not an RM2::Input");
    in = get_open_input(mrb, v);
    pfds[i].fd = in->fd;
    pfds[i].events = POLLIN;
    pfds[i].revents = 0;
  }

  n = poll(pfds, (nfds_t)len, (int)timeout);
  if (n < 0) {
    if (errno == EINTR) return mrb_false_value();
    mrb_sys_fail(mrb, "poll input devices");
  }
  return mrb_bool_value(n > 0);
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

  mrb_define_const(mrb, cls, "PEN", mrb_int_value(mrb, RM2_TOOL_PEN));
  mrb_define_const(mrb, cls, "RUBBER", mrb_int_value(mrb, RM2_TOOL_RUBBER));
  mrb_define_const(mrb, cls, "TOUCH", mrb_int_value(mrb, RM2_TOOL_TOUCH));
  mrb_define_const(mrb, cls, "MAX_WAIT", mrb_int_value(mrb, RM2_MAX_WAIT));
  mrb_define_const(mrb, cls, "NONBLOCK", mrb_int_value(mrb, O_NONBLOCK));
  mrb_define_const(mrb, cls, "EVENT_SIZE",
                   mrb_int_value(mrb, (mrb_int)sizeof(struct input_event)));
}
