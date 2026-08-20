/* mrbgems/mruby-rm2/src/display.c
 *
 * Client side of the rm2fb display-server protocol (PLAN.md §3, verified
 * against rM2-stuff libs/rm2fb/include/rm2fb/Message.h). Wire format:
 * int32 variant tag + raw little-endian struct, strict request/reply.
 */
#include <mruby.h>
#include <mruby/class.h>
#include <mruby/data.h>
#include <mruby/error.h>

#include <errno.h>
#include <stdint.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>

enum { TAG_INIT = 0, TAG_UPDATE = 2 };

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

static int
read_exact(int fd, void* buf, size_t len) {
  char* p = (char*)buf;
  while (len > 0) {
    ssize_t n = read(fd, p, len);
    if (n < 0) {
      if (errno == EINTR) continue;
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
  int sock, fb_fd;
  int32_t tag = TAG_INIT;
  init_msg init;
  fb_format granted;
  size_t total;
  void* mem;
  rm2_display* d;

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
  fb_fd = recv_fd(sock);
  if (fb_fd < 0) {
    close(sock);
    mrb_raise(mrb, E_RUNTIME_ERROR, "server sent no framebuffer fd");
  }
  if (granted.pixel_format != 0 || granted.width <= 0 || granted.height <= 0) {
    close(fb_fd);
    close(sock);
    mrb_raise(mrb, E_RUNTIME_ERROR, "server granted an unsupported buffer format");
  }

  /* RGB565 plane + 1-byte gray plane (PLAN.md §3). */
  total = (size_t)granted.width * granted.height * 3;
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
}
