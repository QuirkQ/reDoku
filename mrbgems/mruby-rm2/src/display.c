/* mrbgems/mruby-rm2/src/display.c
 *
 * Client side of the rm2fb display-server protocol (PLAN.md §3, verified
 * against rM2-stuff libs/rm2fb/include/rm2fb/Message.h). Wire format:
 * int32 variant tag + raw little-endian struct, strict request/reply.
 */
#include "rm2.h"

#include <mruby.h>
#include <mruby/class.h>
#include <mruby/data.h>
#include <mruby/error.h>

#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/time.h>
#include <sys/un.h>
#include <unistd.h>

/* Largest coordinate (either sign) and largest line span draw_line accepts.
 * Both, deliberately: bounding only the span leaves the subtraction that
 * computes it free to overflow first (see rm2_display_draw_line). */
#define RM2_MAX_SPAN 65535

/* Receive timeout on the display socket, seconds. Generous on purpose: a
 * GC16 SYNC update legitimately takes about a second, so anything tight
 * would break normal drawing. */
#define RM2_RECV_TIMEOUT_SEC 10

/* EINTR restarts allowed per read_exact call. Every reply on this socket is
 * a handful of bytes read in one go and signals are rare, so a correct
 * client never comes close; the bound is there so the call cannot be kept
 * alive indefinitely by a signal that keeps arriving. */
#define RM2_EINTR_RETRIES 16

enum { TAG_INIT = 0, TAG_UPDATE = 2, TAG_OPEN_INPUT = 4 };

typedef struct {
  int32_t width;
  int32_t height;
  int32_t pixel_format; /* 0 = RGB565, 1 = RGB32 */
} fb_format;

typedef struct {
  uint8_t own_swtcon;
  uint8_t pad[3];
  fb_format format;
} init_msg; /* 16 bytes on both target ABIs */

typedef struct {
  int32_t y1, x1, y2, x2; /* inclusive corners, y first */
  int32_t flags;
  int32_t waveform;
  float temperature;
  int32_t extra_mode;
} update_params; /* 32 bytes on both target ABIs */

typedef struct {
  char path[64];
  int32_t flags;
} open_input_msg; /* 68 bytes on both target ABIs */

/* Wire structs must be byte-identical on host x86-64 and armv7hf. */
typedef char rm2_init_msg_size_check[(sizeof(init_msg) == 16) ? 1 : -1];
typedef char rm2_update_params_size_check[(sizeof(update_params) == 32) ? 1 : -1];
typedef char rm2_open_input_msg_size_check[(sizeof(open_input_msg) == 68) ? 1 : -1];

typedef struct {
  int sock;
  uint16_t* fb;    /* RGB565 plane; NULL once closed */
  size_t map_size; /* full mapping incl. the trailing gray plane */
  int32_t width;
  int32_t height;
} rm2_display;

static void
rm2_display_dfree(mrb_state* mrb, void* p) {
  rm2_display* d = (rm2_display*)p;
  if (d == NULL) return;
  if (d->fb != NULL) munmap(d->fb, d->map_size);
  if (d->sock >= 0) close(d->sock);
  mrb_free(mrb, d);
}

static const struct mrb_data_type rm2_display_type = {
  "RM2::Display", rm2_display_dfree
};

/* MSG_NOSIGNAL: a dead server must surface as EPIPE, not kill the VM. */
static int
write_exact(int fd, const void* buf, size_t len) {
  const char* p = (const char*)buf;
  while (len > 0) {
    ssize_t n = send(fd, p, len, MSG_NOSIGNAL);
    if (n < 0) {
      if (errno == EINTR) continue;
      return -1;
    }
    p += n;
    len -= (size_t)n;
  }
  return 0;
}

/* Every read on this socket is a reply to a request we just sent, so it
 * either arrives or the server is broken. Two things keep a broken server
 * from parking us here for ever: the socket's SO_RCVTIMEO (armed in
 * rm2_display_open), which surfaces as EAGAIN, and the retry bound below.
 * Without them a server that accepts an update and never acks it wedges the
 * game past SIGTERM — the handlers only set a flag, and nothing in C polls
 * it — while xochitl stays SIGSTOPped behind a frozen panel. */
static int
read_exact(int fd, void* buf, size_t len) {
  char* p = (char*)buf;
  int retries = RM2_EINTR_RETRIES;
  while (len > 0) {
    ssize_t n = read(fd, p, len);
    if (n < 0) {
      if (errno == EINTR && retries-- > 0) continue;
      return -1;
    }
    if (n == 0) {
      errno = ECONNRESET;
      return -1;
    }
    p += n;
    len -= (size_t)n;
  }
  return 0;
}

static int
recv_fd(int sock) {
  char dummy;
  struct iovec iov;
  union {
    struct cmsghdr align;
    char buf[CMSG_SPACE(sizeof(int))];
  } u;
  struct msghdr msg;
  struct cmsghdr* c;
  ssize_t n;
  int fd;

  iov.iov_base = &dummy;
  iov.iov_len = 1;
  memset(&msg, 0, sizeof(msg));
  msg.msg_iov = &iov;
  msg.msg_iovlen = 1;
  msg.msg_control = u.buf;
  msg.msg_controllen = sizeof(u.buf);

  do {
    n = recvmsg(sock, &msg, 0);
  } while (n < 0 && errno == EINTR);
  if (n <= 0) return -1;

  c = CMSG_FIRSTHDR(&msg);
  if (c == NULL || c->cmsg_level != SOL_SOCKET || c->cmsg_type != SCM_RIGHTS)
    return -1;
  if (c->cmsg_len != CMSG_LEN(sizeof(int)) || (msg.msg_flags & MSG_CTRUNC) != 0) {
    /* The kernel may still have installed an fd (e.g. a second, truncated
     * one after the first) even though the message as a whole is rejected;
     * close it rather than leaking it into the process. */
    if (c->cmsg_len >= CMSG_LEN(sizeof(int))) {
      memcpy(&fd, CMSG_DATA(c), sizeof(fd));
      close(fd);
    }
    return -1;
  }
  memcpy(&fd, CMSG_DATA(c), sizeof(fd));
  return fd;
}

/* Raise a SystemCallError without letting close() clobber errno. */
static void
fail_close(mrb_state* mrb, int fd1, int fd2, const char* msg) {
  int e = errno;
  if (fd1 >= 0) close(fd1);
  if (fd2 >= 0) close(fd2);
  errno = e;
  mrb_sys_fail(mrb, msg);
}

static rm2_display*
get_open_display(mrb_state* mrb, mrb_value self) {
  rm2_display* d = DATA_GET_PTR(mrb, self, &rm2_display_type, rm2_display);
  if (d == NULL || d->fb == NULL)
    mrb_raise(mrb, E_RUNTIME_ERROR, "display is closed");
  return d;
}

static mrb_value
rm2_display_open(mrb_state* mrb, mrb_value klass) {
  const char* path = "/var/run/rm2fb.sock";
  struct sockaddr_un addr;
  struct timeval tv;
  int sock, fb_fd;
  int32_t tag = TAG_INIT;
  init_msg init;
  fb_format granted;
  size_t total;
  void* mem;
  rm2_display* d;
  struct stat st;

  mrb_get_args(mrb, "|z", &path);

  sock = socket(AF_UNIX, SOCK_STREAM, 0);
  if (sock < 0) mrb_sys_fail(mrb, "socket");

  memset(&addr, 0, sizeof(addr));
  addr.sun_family = AF_UNIX;
  if (strlen(path) >= sizeof(addr.sun_path)) {
    close(sock);
    mrb_raise(mrb, E_ARGUMENT_ERROR, "socket path too long");
  }
  strcpy(addr.sun_path, path);
  if (connect(sock, (struct sockaddr*)&addr, sizeof(addr)) < 0)
    fail_close(mrb, sock, -1, "connect to rm2fb socket");

  /* Armed before the first exchange, as on the control socket (control.c:
   * "the server simply does not answer some failures"), so even the Init
   * handshake cannot hang. A server that goes quiet now surfaces as a
   * SystemCallError instead of an unkillable client. */
  tv.tv_sec = RM2_RECV_TIMEOUT_SEC;
  tv.tv_usec = 0;
  if (setsockopt(sock, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv)) < 0)
    fail_close(mrb, sock, -1, "set display socket receive timeout");

  memset(&init, 0, sizeof(init));
  init.own_swtcon = 0;
  init.format.width = 1404;
  init.format.height = 1872;
  init.format.pixel_format = 0; /* RGB565 */
  if (write_exact(sock, &tag, sizeof(tag)) < 0 ||
      write_exact(sock, &init, sizeof(init)) < 0)
    fail_close(mrb, sock, -1, "send Init");

  if (read_exact(sock, &granted, sizeof(granted)) < 0)
    fail_close(mrb, sock, -1, "read Init reply");
  if (granted.pixel_format != 0 || granted.width <= 0 || granted.height <= 0) {
    close(sock);
    mrb_raise(mrb, E_RUNTIME_ERROR, "server granted an unsupported buffer format");
  }
  fb_fd = recv_fd(sock);
  if (fb_fd < 0) {
    close(sock);
    mrb_raise(mrb, E_RUNTIME_ERROR, "server sent no framebuffer fd");
  }

  /* RGB565 plane + 1-byte gray plane (PLAN.md §3). */
  total = (size_t)granted.width * granted.height * 3;
  if (fstat(fb_fd, &st) < 0)
    fail_close(mrb, fb_fd, sock, "fstat framebuffer fd");
  if ((size_t)st.st_size < total) {
    close(fb_fd);
    close(sock);
    mrb_raise(mrb, E_RUNTIME_ERROR, "framebuffer fd smaller than granted format");
  }

  mem = mmap(NULL, total, PROT_READ | PROT_WRITE, MAP_SHARED, fb_fd, 0);
  close(fb_fd); /* the mapping keeps the buffer alive */
  if (mem == MAP_FAILED)
    fail_close(mrb, sock, -1, "mmap framebuffer");

  d = (rm2_display*)mrb_malloc(mrb, sizeof(rm2_display));
  d->sock = sock;
  d->fb = (uint16_t*)mem;
  d->map_size = total;
  d->width = granted.width;
  d->height = granted.height;

  return mrb_obj_value(
    mrb_data_object_alloc(mrb, mrb_class_ptr(klass), d, &rm2_display_type));
}

static mrb_value
rm2_display_width(mrb_state* mrb, mrb_value self) {
  return mrb_int_value(mrb, get_open_display(mrb, self)->width);
}

static mrb_value
rm2_display_height(mrb_state* mrb, mrb_value self) {
  return mrb_int_value(mrb, get_open_display(mrb, self)->height);
}

static mrb_value
rm2_display_close(mrb_state* mrb, mrb_value self) {
  rm2_display* d = DATA_GET_PTR(mrb, self, &rm2_display_type, rm2_display);
  if (d != NULL) {
    if (d->fb != NULL) {
      munmap(d->fb, d->map_size);
      d->fb = NULL;
    }
    if (d->sock >= 0) {
      close(d->sock);
      d->sock = -1;
    }
  }
  return mrb_nil_value();
}

static mrb_value
rm2_display_closed_p(mrb_state* mrb, mrb_value self) {
  rm2_display* d = DATA_GET_PTR(mrb, self, &rm2_display_type, rm2_display);
  return mrb_bool_value(d == NULL || d->fb == NULL);
}

/* Gray 0..255 -> RGB565 (PLAN.md §3). */
static uint16_t
rm2_gray565(mrb_int gray) {
  return (uint16_t)((gray >> 3) | ((gray >> 2) << 5) | ((gray >> 3) << 11));
}

/* One brush stamp: a `width`-sided square centred on (x, y), clipped. */
static void
rm2_stamp(rm2_display* d, mrb_int x, mrb_int y, mrb_int width, uint16_t px) {
  mrb_int half = width / 2;
  mrb_int x1 = x - half, y1 = y - half;
  mrb_int x2 = x1 + width, y2 = y1 + width;
  mrb_int row, col;

  if (x1 < 0) x1 = 0;
  if (y1 < 0) y1 = 0;
  if (x2 > d->width) x2 = d->width;
  if (y2 > d->height) y2 = d->height;
  if (x1 >= x2 || y1 >= y2) return;
  for (row = y1; row < y2; row++) {
    uint16_t* p = d->fb + (size_t)row * d->width + x1;
    for (col = x1; col < x2; col++) *p++ = px;
  }
}

static mrb_value
rm2_display_fill_rect(mrb_state* mrb, mrb_value self) {
  mrb_int x, y, w, h, gray;
  rm2_display* d;
  mrb_int x2, y2, row, col;
  uint16_t px;

  mrb_get_args(mrb, "iiiii", &x, &y, &w, &h, &gray);
  d = get_open_display(mrb, self);

  if (gray < 0 || gray > 255)
    mrb_raise(mrb, E_ARGUMENT_ERROR, "gray must be 0..255");
  if (w < 0 || h < 0)
    mrb_raise(mrb, E_ARGUMENT_ERROR, "width and height must be >= 0");

  x2 = x + w; /* exclusive */
  y2 = y + h;
  if (x < 0) x = 0;
  if (y < 0) y = 0;
  if (x2 > d->width) x2 = d->width;
  if (y2 > d->height) y2 = d->height;
  if (x >= x2 || y >= y2) return self;

  px = rm2_gray565(gray);
  for (row = y; row < y2; row++) {
    uint16_t* p = d->fb + (size_t)row * d->width + x;
    for (col = x; col < x2; col++) *p++ = px;
  }
  return self;
}

static mrb_value
rm2_display_pixel(mrb_state* mrb, mrb_value self) {
  mrb_int x, y;
  rm2_display* d;

  mrb_get_args(mrb, "ii", &x, &y);
  d = get_open_display(mrb, self);
  if (x < 0 || x >= d->width || y < 0 || y >= d->height)
    mrb_raise(mrb, E_RANGE_ERROR, "pixel out of bounds");
  return mrb_int_value(mrb, d->fb[(size_t)y * d->width + x]);
}

/* mrb_int is int64 on the host build and int32 on the armv7 device (mruby
 * picks MRB_INT32 for a 32-bit target), which is why every coordinate is
 * bounded here and not just their difference: on the device a pair 2^31
 * apart makes x2 - x1 come out NEGATIVE, so it sails through the span guard
 * below, and Bresenham is then left with an exit condition
 * (x1 == x2 && y1 == y2) it can never reach. That is an infinite loop
 * inside C, where nothing polls RM2.terminated?, on a client the server has
 * SIGSTOPped xochitl behind: a frozen panel at 100% CPU that only SIGKILL
 * ends. Bounding the coordinates makes x2 - x1, x1 - x2 and rm2_stamp's
 * x1 + width all provably in range on both ABIs. The wrap itself is
 * host-invisible; test/display.rb pins the rejection, which is not. */
static void
check_coord(mrb_state* mrb, mrb_int v) {
  /* %i consumes an mrb_int and %d a plain int (mruby 4.0's mrb_vformat, in
   * its src/error.c) — they are not interchangeable, and an mrb_int passed
   * to %d is a varargs type mismatch wherever the two differ in width, as
   * they do on the host. Hence %i here, and hence the casts. */
  if (v < -RM2_MAX_SPAN || v > RM2_MAX_SPAN)
    mrb_raisef(mrb, E_ARGUMENT_ERROR, "coordinate must be within -%i..%i",
               (mrb_int)RM2_MAX_SPAN, (mrb_int)RM2_MAX_SPAN);
}

static mrb_value
rm2_display_draw_line(mrb_state* mrb, mrb_value self) {
  mrb_int x1, y1, x2, y2, width, gray;
  rm2_display* d;
  mrb_int dx, dy, sx, sy, err, e2;
  uint16_t px;

  mrb_get_args(mrb, "iiiiii", &x1, &y1, &x2, &y2, &width, &gray);
  d = get_open_display(mrb, self);

  if (gray < 0 || gray > 255)
    mrb_raise(mrb, E_ARGUMENT_ERROR, "gray must be 0..255");
  if (width < 1 || width > RM2_MAX_SPAN)
    mrb_raise(mrb, E_ARGUMENT_ERROR, "width must be >= 1 and <= 65535");
  check_coord(mrb, x1);
  check_coord(mrb, y1);
  check_coord(mrb, x2);
  check_coord(mrb, y2);

  /* Still worth its own check: two in-bounds coordinates can be 131070
   * apart, and the brush is stamped once per pixel of the longer axis. */
  dx = x2 > x1 ? x2 - x1 : x1 - x2;
  dy = y2 > y1 ? y2 - y1 : y1 - y2;
  if (dx > RM2_MAX_SPAN || dy > RM2_MAX_SPAN)
    mrb_raise(mrb, E_ARGUMENT_ERROR, "line span too large");

  px = rm2_gray565(gray);
  sx = x1 < x2 ? 1 : -1;
  sy = y1 < y2 ? 1 : -1;
  err = dx - dy;
  for (;;) {
    rm2_stamp(d, x1, y1, width, px);
    if (x1 == x2 && y1 == y2) break;
    e2 = 2 * err;
    if (e2 > -dy) {
      err -= dy;
      x1 += sx;
    }
    if (e2 < dx) {
      err += dx;
      y1 += sy;
    }
  }
  return self;
}

static mrb_value
rm2_display_update_raw(mrb_state* mrb, mrb_value self) {
  mrb_int x, y, w, h, waveform, flags;
  rm2_display* d;
  mrb_int x2, y2;
  int32_t tag = TAG_UPDATE;
  update_params up;
  uint8_t ack;

  mrb_get_args(mrb, "iiiiii", &x, &y, &w, &h, &waveform, &flags);
  d = get_open_display(mrb, self);

  if (w < 0 || h < 0)
    mrb_raise(mrb, E_ARGUMENT_ERROR, "width and height must be >= 0");

  x2 = x + w; /* exclusive */
  y2 = y + h;
  if (x < 0) x = 0;
  if (y < 0) y = 0;
  if (x2 > d->width) x2 = d->width;
  if (y2 > d->height) y2 = d->height;
  if (x >= x2 || y >= y2) return mrb_true_value(); /* nothing to flush */

  up.y1 = (int32_t)y;
  up.x1 = (int32_t)x;
  up.y2 = (int32_t)(y2 - 1); /* inclusive corners */
  up.x2 = (int32_t)(x2 - 1);
  up.flags = (int32_t)flags;
  up.waveform = (int32_t)waveform;
  up.temperature = 0.0f;
  up.extra_mode = 0;

  if (write_exact(d->sock, &tag, sizeof(tag)) < 0 ||
      write_exact(d->sock, &up, sizeof(up)) < 0)
    mrb_sys_fail(mrb, "send update");
  if (read_exact(d->sock, &ack, sizeof(ack)) < 0)
    mrb_sys_fail(mrb, "read update ack");
  return mrb_bool_value(ack != 0);
}

/* Asks the server to open an evdev node for us and pass back the fd. Going
 * through the server (rather than open()ing it ourselves) is what lets it
 * discard our stale event backlog while we are SIGSTOPped. */
static mrb_value
rm2_display_open_input(mrb_state* mrb, mrb_value self) {
  const char* path;
  mrb_int flags = O_RDONLY | O_NONBLOCK;
  rm2_display* d;
  int32_t tag = TAG_OPEN_INPUT;
  open_input_msg req;
  uint8_t ok;
  int fd;

  mrb_get_args(mrb, "z|i", &path, &flags);
  d = get_open_display(mrb, self);

  memset(&req, 0, sizeof(req));
  if (strlen(path) >= sizeof(req.path))
    mrb_raise(mrb, E_ARGUMENT_ERROR, "input device path too long");
  strcpy(req.path, path);
  req.flags = (int32_t)flags;

  if (write_exact(d->sock, &tag, sizeof(tag)) < 0 ||
      write_exact(d->sock, &req, sizeof(req)) < 0)
    mrb_sys_fail(mrb, "send OpenInputDevice");
  if (read_exact(d->sock, &ok, sizeof(ok)) < 0)
    mrb_sys_fail(mrb, "read OpenInputDevice reply");
  if (ok == 0)
    mrb_raisef(mrb, E_RUNTIME_ERROR, "server could not open input device %s",
               path);

  fd = recv_fd(d->sock);
  if (fd < 0)
    mrb_raise(mrb, E_RUNTIME_ERROR, "server sent no input device fd");
  return rm2_input_new(mrb, fd);
}

void
rm2_display_init(mrb_state* mrb, struct RClass* rm2) {
  struct RClass* cls =
    mrb_define_class_under(mrb, rm2, "Display", mrb->object_class);
  MRB_SET_INSTANCE_TT(cls, MRB_TT_CDATA);
  mrb_define_class_method(mrb, cls, "open", rm2_display_open, MRB_ARGS_OPT(1));
  mrb_define_method(mrb, cls, "width", rm2_display_width, MRB_ARGS_NONE());
  mrb_define_method(mrb, cls, "height", rm2_display_height, MRB_ARGS_NONE());
  mrb_define_method(mrb, cls, "close", rm2_display_close, MRB_ARGS_NONE());
  mrb_define_method(mrb, cls, "closed?", rm2_display_closed_p, MRB_ARGS_NONE());
  mrb_define_method(mrb, cls, "fill_rect", rm2_display_fill_rect, MRB_ARGS_REQ(5));
  mrb_define_method(mrb, cls, "pixel", rm2_display_pixel, MRB_ARGS_REQ(2));
  mrb_define_method(mrb, cls, "draw_line", rm2_display_draw_line, MRB_ARGS_REQ(6));
  mrb_define_method(mrb, cls, "update_raw", rm2_display_update_raw, MRB_ARGS_REQ(6));
  mrb_define_method(mrb, cls, "open_input", rm2_display_open_input,
                    MRB_ARGS_ARG(1, 1));
}
