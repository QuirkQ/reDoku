/* mrbgems/mruby-rm2/src/inotify.c
 *
 * A thin wrapper over Linux inotify for the hijack watcher (`redoku
 * --watch`, PLAN.md §10): watch the decoy document's `.pdf` (IN_OPEN) and
 * its `.metadata` (IN_CLOSE_WRITE) for xochitl touching them, spawn the
 * game. Which of the two actually fires on-device is unverified this
 * session (no cable) — both masks are exposed and host-tested here; the
 * empirical pick is a device-checklist step, not a code fork (M4-HIJACK
 * ledger, ruling R1).
 *
 * inotify_init1(IN_CLOEXEC | IN_NONBLOCK) buys both invariants of this
 * object in the one syscall that creates its fd:
 *
 *  - CLOEXEC: a game spawned by RM2.spawn_detached must not inherit the
 *    watch fd. Unlike input.c's fd — which arrives already open, over the
 *    display connection, with flags the caller chose — this fd is ours
 *    from the moment it exists, so there is no F_GETFL/F_SETFL dance to
 *    preserve a caller's flags; one syscall sets both.
 *  - NONBLOCK: #read_events drains until EAGAIN and must never park the
 *    watcher's one thread waiting for a filesystem event that may not come
 *    for hours. Waiting-with-a-timeout is a separate, explicit step
 *    (#wait), same split as RM2::Input.
 */
#include "rm2.h"

#include <mruby/array.h>
#include <mruby/data.h>
#include <mruby/error.h>

#include <errno.h>
#include <limits.h>
#include <poll.h>
#include <string.h>
#include <sys/inotify.h>
#include <unistd.h>

/* Events per read() drain pass, the same batching idea as input.c's
 * RM2_READ_EVENTS: bounded so one #read_events call cannot pin an
 * arbitrarily large stack buffer, generous enough that the watcher's two
 * watches (pdf + metadata) never fill it in one debounce window. */
#define RM2_INOTIFY_READ_EVENTS 16
/* NAME_MAX (255 on Linux) is the kernel's own bound on an inotify_event's
 * name[]; +1 leaves room for the NUL a hand-rolled string would have,
 * though the decode below uses strnlen(..., ev.len) and never assumes
 * one is there. */
#define RM2_INOTIFY_BUF_LEN \
  (RM2_INOTIFY_READ_EVENTS * (sizeof(struct inotify_event) + NAME_MAX + 1))

typedef struct {
  int fd;
} rm2_inotify;

static void
rm2_inotify_dfree(mrb_state* mrb, void* p) {
  rm2_inotify* iw = (rm2_inotify*)p;
  if (iw == NULL) return;
  if (iw->fd >= 0) close(iw->fd);
  mrb_free(mrb, iw);
}

static const struct mrb_data_type rm2_inotify_type = { "RM2::Inotify",
                                                        rm2_inotify_dfree };

static rm2_inotify*
get_open_inotify(mrb_state* mrb, mrb_value self) {
  rm2_inotify* iw = DATA_GET_PTR(mrb, self, &rm2_inotify_type, rm2_inotify);
  if (iw == NULL || iw->fd < 0)
    mrb_raise(mrb, E_RUNTIME_ERROR, "inotify is closed");
  return iw;
}

static mrb_value
rm2_inotify_s_init(mrb_state* mrb, mrb_value klass) {
  struct RClass* cls = mrb_class_ptr(klass);
  rm2_inotify* iw;
  int fd = inotify_init1(IN_CLOEXEC | IN_NONBLOCK);
  if (fd < 0) mrb_sys_fail(mrb, "inotify_init1");

  iw = (rm2_inotify*)mrb_malloc(mrb, sizeof(rm2_inotify));
  iw->fd = fd;
  return mrb_obj_value(mrb_data_object_alloc(mrb, cls, iw, &rm2_inotify_type));
}

static mrb_value
rm2_inotify_watch(mrb_state* mrb, mrb_value self) {
  rm2_inotify* iw = get_open_inotify(mrb, self);
  const char* path;
  mrb_int mask;
  int wd;

  mrb_get_args(mrb, "zi", &path, &mask);
  wd = inotify_add_watch(iw->fd, path, (uint32_t)mask);
  if (wd < 0) mrb_sys_fail(mrb, "inotify_add_watch");
  return mrb_int_value(mrb, wd);
}

static mrb_value
rm2_inotify_read_events(mrb_state* mrb, mrb_value self) {
  rm2_inotify* iw = get_open_inotify(mrb, self);
  char buf[RM2_INOTIFY_BUF_LEN];
  mrb_value out = mrb_ary_new(mrb);
  int ai = mrb_gc_arena_save(mrb);

  for (;;) {
    ssize_t n = read(iw->fd, buf, sizeof(buf));
    size_t off;

    if (n < 0) {
      if (errno == EINTR) continue;
      if (errno == EAGAIN || errno == EWOULDBLOCK) break;
      mrb_sys_fail(mrb, "read inotify fd");
    }
    if (n == 0) break; /* no EOF concept for inotify; nothing to parse */

    off = 0;
    while (off < (size_t)n) {
      struct inotify_event ev;
      mrb_value tuple, name;

      if (off + sizeof(ev) > (size_t)n)
        mrb_raise(mrb, E_RUNTIME_ERROR, "short read from inotify fd");
      /* memcpy, not a cast of buf+off to struct inotify_event*: off is not
       * guaranteed aligned for the struct's uint32_t fields (mirrors
       * control.c's wire-struct parsing, same reasoning). */
      memcpy(&ev, buf + off, sizeof(ev));
      /* The kernel never sends a name longer than NAME_MAX, so this also
       * guards the addition just below from wrapping a 32-bit size_t (the
       * device build is armv7) the way control.c's client-count bound
       * guards its own multiply. */
      if (ev.len > NAME_MAX)
        mrb_raise(mrb, E_RUNTIME_ERROR, "implausible inotify event name length");
      if (off + sizeof(ev) + ev.len > (size_t)n)
        mrb_raise(mrb, E_RUNTIME_ERROR, "truncated inotify event");

      name = mrb_str_new(mrb, buf + off + sizeof(ev),
                          strnlen(buf + off + sizeof(ev), ev.len));
      tuple = mrb_ary_new_capa(mrb, 4);
      mrb_ary_push(mrb, tuple, mrb_int_value(mrb, ev.wd));
      mrb_ary_push(mrb, tuple, mrb_int_value(mrb, (mrb_int)ev.mask));
      mrb_ary_push(mrb, tuple, mrb_int_value(mrb, (mrb_int)ev.cookie));
      mrb_ary_push(mrb, tuple, name);
      mrb_ary_push(mrb, out, tuple);
      mrb_gc_arena_restore(mrb, ai);
      mrb_gc_protect(mrb, out);

      off += sizeof(ev) + ev.len;
    }
    if ((size_t)n < sizeof(buf)) break; /* drained this pass */
  }
  return out;
}

static mrb_value
rm2_inotify_fd(mrb_state* mrb, mrb_value self) {
  return mrb_int_value(mrb, get_open_inotify(mrb, self)->fd);
}

static mrb_value
rm2_inotify_close(mrb_state* mrb, mrb_value self) {
  rm2_inotify* iw = DATA_GET_PTR(mrb, self, &rm2_inotify_type, rm2_inotify);
  if (iw != NULL && iw->fd >= 0) {
    close(iw->fd);
    iw->fd = -1;
  }
  return mrb_nil_value();
}

static mrb_value
rm2_inotify_closed_p(mrb_state* mrb, mrb_value self) {
  rm2_inotify* iw = DATA_GET_PTR(mrb, self, &rm2_inotify_type, rm2_inotify);
  return mrb_bool_value(iw == NULL || iw->fd < 0);
}

/* RM2::Inotify#wait(timeout_ms) -> true if events are pending. Mirrors
 * RM2::Input.wait's poll() pattern (EINTR returns false instead of
 * restarting, so the watcher's loop gets a turn to check RM2.terminated?
 * and RM2.reload?) but scoped to the one fd this object owns: unlike
 * Input, a watcher never needs to wait on several Inotify instances at
 * once, so there is no array-of-sources form here. */
static mrb_value
rm2_inotify_wait(mrb_state* mrb, mrb_value self) {
  rm2_inotify* iw = get_open_inotify(mrb, self);
  mrb_int timeout;
  struct pollfd pfd;
  int n;

  mrb_get_args(mrb, "i", &timeout);
  if (timeout < 0)
    mrb_raise(mrb, E_ARGUMENT_ERROR, "timeout must be >= 0 milliseconds");

  pfd.fd = iw->fd;
  pfd.events = POLLIN;
  pfd.revents = 0;

  n = poll(&pfd, 1, timeout > (mrb_int)INT_MAX ? INT_MAX : (int)timeout);
  if (n < 0) {
    if (errno == EINTR) return mrb_false_value();
    mrb_sys_fail(mrb, "poll inotify fd");
  }
  return mrb_bool_value((pfd.revents & POLLIN) != 0);
}

void
rm2_inotify_init(mrb_state* mrb, struct RClass* rm2) {
  struct RClass* cls =
    mrb_define_class_under(mrb, rm2, "Inotify", mrb->object_class);
  MRB_SET_INSTANCE_TT(cls, MRB_TT_CDATA);
  /* Like RM2::Input, one blessed construction path: .init both allocates
   * the wrapper and opens the fd together, so there is no half-built
   * instance a bare .new could hand back. */
  mrb_undef_class_method(mrb, cls, "new");
  mrb_define_class_method(mrb, cls, "init", rm2_inotify_s_init,
                          MRB_ARGS_NONE());
  mrb_define_method(mrb, cls, "watch", rm2_inotify_watch, MRB_ARGS_REQ(2));
  mrb_define_method(mrb, cls, "read_events", rm2_inotify_read_events,
                    MRB_ARGS_NONE());
  mrb_define_method(mrb, cls, "wait", rm2_inotify_wait, MRB_ARGS_REQ(1));
  mrb_define_method(mrb, cls, "fd", rm2_inotify_fd, MRB_ARGS_NONE());
  mrb_define_method(mrb, cls, "close", rm2_inotify_close, MRB_ARGS_NONE());
  mrb_define_method(mrb, cls, "closed?", rm2_inotify_closed_p, MRB_ARGS_NONE());

  mrb_define_const(mrb, cls, "IN_OPEN", mrb_int_value(mrb, IN_OPEN));
  mrb_define_const(mrb, cls, "IN_CLOSE_WRITE", mrb_int_value(mrb, IN_CLOSE_WRITE));
  mrb_define_const(mrb, cls, "IN_MODIFY", mrb_int_value(mrb, IN_MODIFY));
  mrb_define_const(mrb, cls, "IN_Q_OVERFLOW", mrb_int_value(mrb, IN_Q_OVERFLOW));
  mrb_define_const(mrb, cls, "IN_IGNORED", mrb_int_value(mrb, IN_IGNORED));
  mrb_define_const(mrb, cls, "IN_DELETE_SELF", mrb_int_value(mrb, IN_DELETE_SELF));
  mrb_define_const(mrb, cls, "IN_MOVE_SELF", mrb_int_value(mrb, IN_MOVE_SELF));
}
