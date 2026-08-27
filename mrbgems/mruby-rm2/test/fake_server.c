/* mrbgems/mruby-rm2/test/fake_server.c
 *
 * In-process fake rm2fb server for mrbtest. Speaks the real wire protocol
 * (PLAN.md §3) on a /tmp unix socket: grants a memfd-backed framebuffer on
 * Init and logs every UpdateParams it receives — raw 32-byte structs
 * appended to a log file — so Ruby tests can assert exact bytes. It also
 * answers OpenInputDevice by open()ing the requested path and passing the
 * fd back over SCM_RIGHTS, logging the 68-byte request verbatim.
 *
 * The listening socket is bound in the parent BEFORE forking, so the
 * socket is connectable the moment RM2::TestServer.start returns.
 *
 * A second, independent fake lives further down: the SOCK_DGRAM control
 * socket (start_control/stop_control), with its own paths, its own child
 * and its own request log. The two share only the read/write helpers, so a
 * test can run either alone.
 */
#define _GNU_SOURCE
#include <mruby.h>
#include <mruby/array.h>
#include <mruby/class.h>
#include <mruby/error.h>
#include <mruby/string.h>

#include <errno.h>
#include <fcntl.h>
#include <linux/input.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <sys/wait.h>
#include <unistd.h>

#define FAKE_FB_WIDTH 1404
#define FAKE_FB_HEIGHT 1872
#define FAKE_FB_TOTAL ((size_t)FAKE_FB_WIDTH * FAKE_FB_HEIGHT * 3)

static pid_t server_pid = -1;
static char sock_path[108];
static char log_path[128];
static char fifo_path[128];
static char open_input_log_path[128];

static pid_t control_pid = -1;
static char control_sock_path[108];
static char control_log_path[128];

static int
fs_write_exact(int fd, const void* buf, size_t len) {
  const char* p = (const char*)buf;
  while (len > 0) {
    ssize_t n = write(fd, p, len);
    if (n < 0) {
      if (errno == EINTR) continue;
      return -1;
    }
    p += n;
    len -= (size_t)n;
  }
  return 0;
}

/* Returns 0 on success, 1 on clean EOF before any byte, -1 on error. */
static int
fs_read_exact(int fd, void* buf, size_t len) {
  char* p = (char*)buf;
  size_t got = 0;
  while (got < len) {
    ssize_t n = read(fd, p + got, len - got);
    if (n < 0) {
      if (errno == EINTR) continue;
      return -1;
    }
    if (n == 0) return got == 0 ? 1 : -1;
    got += (size_t)n;
  }
  return 0;
}

static int
fs_send_fd(int sock, int fd) {
  char dummy = 0;
  struct iovec iov;
  union {
    struct cmsghdr align;
    char buf[CMSG_SPACE(sizeof(int))];
  } u;
  struct msghdr msg;
  struct cmsghdr* c;

  iov.iov_base = &dummy;
  iov.iov_len = 1;
  memset(&msg, 0, sizeof(msg));
  msg.msg_iov = &iov;
  msg.msg_iovlen = 1;
  msg.msg_control = u.buf;
  msg.msg_controllen = sizeof(u.buf);
  c = CMSG_FIRSTHDR(&msg);
  c->cmsg_level = SOL_SOCKET;
  c->cmsg_type = SCM_RIGHTS;
  c->cmsg_len = CMSG_LEN(sizeof(int));
  memcpy(CMSG_DATA(c), &fd, sizeof(fd));
  return sendmsg(sock, &msg, 0) == 1 ? 0 : -1;
}

static void
fs_serve(int listen_fd, int log_fd) {
  int client = accept(listen_fd, NULL, NULL);
  if (client < 0) _exit(1);

  for (;;) {
    int32_t tag;
    int r = fs_read_exact(client, &tag, sizeof(tag));
    if (r == 1) _exit(0); /* client closed cleanly between messages */
    if (r < 0) _exit(1);

    if (tag == 0) { /* Init: 16-byte payload */
      char init[16];
      int32_t granted[3] = { FAKE_FB_WIDTH, FAKE_FB_HEIGHT, 0 /* RGB565 */ };
      int fb;
      if (fs_read_exact(client, init, sizeof(init)) != 0) _exit(1);
      fb = memfd_create("rm2fb-test", 0);
      if (fb < 0) _exit(1);
      if (ftruncate(fb, (off_t)FAKE_FB_TOTAL) < 0) _exit(1);
      if (fs_write_exact(client, granted, sizeof(granted)) < 0) _exit(1);
      if (fs_send_fd(client, fb) < 0) _exit(1);
      close(fb); /* client's mmap keeps the memory alive */
    }
    else if (tag == 2) { /* UpdateParams: 32-byte payload */
      char params[32];
      uint8_t ack = 1;
      if (fs_read_exact(client, params, sizeof(params)) != 0) _exit(1);
      if (fs_write_exact(log_fd, params, sizeof(params)) < 0) _exit(1);
      if (fs_write_exact(client, &ack, sizeof(ack)) < 0) _exit(1);
    }
    else if (tag == 4) { /* OpenInputDevice: 68-byte payload */
      char req[68];
      int32_t flags;
      uint8_t ok;
      int fd, log;
      if (fs_read_exact(client, req, sizeof(req)) != 0) _exit(1);
      log = open(open_input_log_path, O_WRONLY | O_CREAT | O_TRUNC, 0644);
      if (log >= 0) {
        if (fs_write_exact(log, req, sizeof(req)) < 0) _exit(1);
        close(log);
      }
      memcpy(&flags, &req[64], sizeof(flags));
      req[63] = '\0';
      fd = open(req, (flags & (O_ACCMODE | O_NONBLOCK)) | O_CLOEXEC);
      ok = fd >= 0 ? 1 : 0;
      if (fs_write_exact(client, &ok, sizeof(ok)) < 0) _exit(1);
      if (fd >= 0) {
        if (fs_send_fd(client, fd) < 0) _exit(1);
        close(fd);
      }
    }
    else {
      _exit(1); /* unknown tag: fail loudly, the test will see a dead server */
    }
  }
}

static mrb_value
fs_start(mrb_state* mrb, mrb_value self) {
  struct sockaddr_un addr;
  int listen_fd, log_fd;
  pid_t pid;

  if (server_pid > 0)
    mrb_raise(mrb, E_RUNTIME_ERROR, "fake rm2fb server already running");

  snprintf(sock_path, sizeof(sock_path), "/tmp/rm2fb-test-%d.sock", (int)getpid());
  snprintf(log_path, sizeof(log_path), "/tmp/rm2fb-test-%d.log", (int)getpid());
  snprintf(open_input_log_path, sizeof(open_input_log_path),
           "/tmp/rm2fb-test-%d.openinput", (int)getpid());
  unlink(sock_path);
  unlink(open_input_log_path); /* a stale log must not read as this run's */

  log_fd = open(log_path, O_WRONLY | O_CREAT | O_TRUNC, 0644);
  if (log_fd < 0) mrb_sys_fail(mrb, "open update log");

  listen_fd = socket(AF_UNIX, SOCK_STREAM, 0);
  if (listen_fd < 0) {
    close(log_fd);
    mrb_sys_fail(mrb, "socket");
  }
  memset(&addr, 0, sizeof(addr));
  addr.sun_family = AF_UNIX;
  strncpy(addr.sun_path, sock_path, sizeof(addr.sun_path) - 1);
  if (bind(listen_fd, (struct sockaddr*)&addr, sizeof(addr)) < 0 ||
      listen(listen_fd, 1) < 0) {
    close(listen_fd);
    close(log_fd);
    mrb_sys_fail(mrb, "bind/listen fake server socket");
  }

  pid = fork();
  if (pid < 0) {
    close(listen_fd);
    close(log_fd);
    mrb_sys_fail(mrb, "fork fake server");
  }
  if (pid == 0) {
    fs_serve(listen_fd, log_fd);
    _exit(0);
  }
  close(listen_fd);
  close(log_fd);
  server_pid = pid;
  return mrb_str_new_cstr(mrb, sock_path);
}

static mrb_value
fs_stop(mrb_state* mrb, mrb_value self) {
  if (server_pid > 0) {
    kill(server_pid, SIGKILL);
    waitpid(server_pid, NULL, 0);
    server_pid = -1;
    unlink(sock_path);
    if (fifo_path[0] != '\0') {
      unlink(fifo_path);
      fifo_path[0] = '\0';
    }
  }
  return mrb_nil_value();
}

static mrb_value
fs_log_path(mrb_state* mrb, mrb_value self) {
  return mrb_str_new_cstr(mrb, log_path);
}

/* A FIFO stands in for an evdev node: nothing to read until a test writes,
 * which is what makes the wait-timeout and decode paths testable. */
static mrb_value
fs_make_fifo(mrb_state* mrb, mrb_value self) {
  snprintf(fifo_path, sizeof(fifo_path), "/tmp/rm2fb-test-%d.fifo",
           (int)getpid());
  unlink(fifo_path);
  if (mkfifo(fifo_path, 0644) < 0) mrb_sys_fail(mrb, "mkfifo");
  return mrb_str_new_cstr(mrb, fifo_path);
}

/* Packs [[type, code, value], …] using the real struct input_event, whose
 * size differs per ABI (16 bytes on armv7, 24 on x86-64). */
static mrb_value
fs_pack_events(mrb_state* mrb, mrb_value self) {
  mrb_value ary, out;
  mrb_int i, len;

  mrb_get_args(mrb, "A", &ary);
  len = RARRAY_LEN(ary);
  out = mrb_str_new(mrb, NULL, 0);
  for (i = 0; i < len; i++) {
    mrb_value triple = mrb_ary_ref(mrb, ary, i);
    struct input_event ev;
    if (RARRAY_LEN(triple) != 3)
      mrb_raise(mrb, E_ARGUMENT_ERROR, "expected [type, code, value]");
    memset(&ev, 0, sizeof(ev));
    ev.type = (unsigned short)mrb_integer(mrb_ary_ref(mrb, triple, 0));
    ev.code = (unsigned short)mrb_integer(mrb_ary_ref(mrb, triple, 1));
    ev.value = (int)mrb_integer(mrb_ary_ref(mrb, triple, 2));
    mrb_str_cat(mrb, out, (const char*)&ev, sizeof(ev));
  }
  return out;
}

static mrb_value
fs_last_open_input(mrb_state* mrb, mrb_value self) {
  char buf[68];
  int fd = open(open_input_log_path, O_RDONLY);
  if (fd < 0) return mrb_nil_value();
  if (fs_read_exact(fd, buf, sizeof(buf)) != 0) {
    close(fd);
    return mrb_nil_value();
  }
  close(fd);
  return mrb_str_new(mrb, buf, sizeof(buf));
}

/* One 52-byte ControlInterface::Client record: pid at 0, active at 4, the
 * FbFormat triple at 8..19, name at 20..51. */
static void
fs_put_client(char* rec, int32_t pid, uint8_t active, const char* name) {
  int32_t fmt[3] = { FAKE_FB_WIDTH, FAKE_FB_HEIGHT, 0 };
  memcpy(rec, &pid, sizeof(pid));
  rec[4] = (char)active;
  memcpy(&rec[8], fmt, sizeof(fmt));
  strncpy(&rec[20], name, 32); /* deliberately may fill all 32, unterminated */
}

/* Canned reply: int32 count, then two 52-byte Client records. */
static void
fs_serve_control(int sock, int log_fd) {
  for (;;) {
    char req[8];
    struct sockaddr_un from;
    socklen_t from_len = sizeof(from);
    ssize_t n = recvfrom(sock, req, sizeof(req), 0, (struct sockaddr*)&from,
                         &from_len);
    int32_t type, pid;

    if (n < 0) {
      if (errno == EINTR) continue;
      _exit(1);
    }
    if (n < (ssize_t)sizeof(req)) continue;
    if (fs_write_exact(log_fd, req, sizeof(req)) < 0) _exit(1);
    memcpy(&type, req, sizeof(type));
    memcpy(&pid, &req[4], sizeof(pid));

    if (type == 0) { /* GetClients */
      char buf[4 + 2 * 52];
      int32_t count = 2;
      memset(buf, 0, sizeof(buf));
      memcpy(buf, &count, sizeof(count));
      fs_put_client(&buf[4], 1232, 1, "xochitl");
      /* Exactly 32 bytes: exercises the unterminated-name case fs_put_client
       * documents but which "redoku" (7 bytes) never reached. */
      fs_put_client(&buf[4 + 52], 4711, 0, "unterminated-32-byte-client-name");
      if (sendto(sock, buf, sizeof(buf), 0, (struct sockaddr*)&from,
                 from_len) < 0)
        _exit(1);
    } else { /* SwitchTo / anything else: one bool */
      uint8_t ok = (type == 2 && pid == 1232) ? 1 : 0;
      if (sendto(sock, &ok, sizeof(ok), 0, (struct sockaddr*)&from,
                 from_len) < 0)
        _exit(1);
    }
  }
}

static mrb_value
fs_start_control(mrb_state* mrb, mrb_value self) {
  struct sockaddr_un addr;
  int sock, log_fd;
  pid_t pid;

  if (control_pid > 0)
    mrb_raise(mrb, E_RUNTIME_ERROR, "fake control server already running");

  snprintf(control_sock_path, sizeof(control_sock_path),
           "/tmp/rm2fb-ctl-%d.sock", (int)getpid());
  snprintf(control_log_path, sizeof(control_log_path), "/tmp/rm2fb-ctl-%d.log",
           (int)getpid());
  unlink(control_sock_path);
  unlink(control_log_path); /* a stale log must not read as this run's */

  log_fd = open(control_log_path, O_WRONLY | O_CREAT | O_TRUNC, 0644);
  if (log_fd < 0) mrb_sys_fail(mrb, "open control log");

  sock = socket(AF_UNIX, SOCK_DGRAM, 0);
  if (sock < 0) {
    close(log_fd);
    mrb_sys_fail(mrb, "control socket");
  }
  memset(&addr, 0, sizeof(addr));
  addr.sun_family = AF_UNIX;
  strncpy(addr.sun_path, control_sock_path, sizeof(addr.sun_path) - 1);
  /* Bound in the parent before the fork, so the socket is addressable the
   * moment start_control returns. */
  if (bind(sock, (struct sockaddr*)&addr, sizeof(addr)) < 0) {
    close(sock);
    close(log_fd);
    mrb_sys_fail(mrb, "bind fake control socket");
  }

  pid = fork();
  if (pid < 0) {
    close(sock);
    close(log_fd);
    mrb_sys_fail(mrb, "fork fake control server");
  }
  if (pid == 0) {
    fs_serve_control(sock, log_fd);
    _exit(0);
  }
  close(sock);
  close(log_fd);
  control_pid = pid;
  return mrb_str_new_cstr(mrb, control_sock_path);
}

static mrb_value
fs_stop_control(mrb_state* mrb, mrb_value self) {
  if (control_pid > 0) {
    kill(control_pid, SIGKILL);
    waitpid(control_pid, NULL, 0);
    control_pid = -1;
    unlink(control_sock_path);
  }
  return mrb_nil_value();
}

/* The last 8-byte Request the fake control server logged, or nil when it
 * has not seen a whole one yet. */
static mrb_value
fs_last_control_request(mrb_state* mrb, mrb_value self) {
  char buf[8];
  int fd = open(control_log_path, O_RDONLY);
  if (fd < 0) return mrb_nil_value();
  if (lseek(fd, -(off_t)sizeof(buf), SEEK_END) < 0 ||
      fs_read_exact(fd, buf, sizeof(buf)) != 0) {
    close(fd);
    return mrb_nil_value();
  }
  close(fd);
  return mrb_str_new(mrb, buf, sizeof(buf));
}

/* Delivers a signal to the test process itself, which is what makes the
 * SIGTERM/SIGCONT flags testable without a second process. */
static mrb_value
fs_raise_signal(mrb_state* mrb, mrb_value self) {
  mrb_int sig;
  mrb_get_args(mrb, "i", &sig);
  if (raise((int)sig) != 0) mrb_sys_fail(mrb, "raise");
  return mrb_nil_value();
}

/* getsid/getpgid, exposed only so mrbtest can prove RM2.spawn_detached's
 * child lands in a session and process group of its own (pid 0 means "the
 * calling process" per POSIX, which is what lets a test ask about itself
 * without a getpid() wrapper too). Nothing in the shim itself needs these
 * — the watcher never queries them — so they stay test-only rather than
 * becoming production API surface. */
static mrb_value
fs_getsid(mrb_state* mrb, mrb_value self) {
  mrb_int pid;
  pid_t sid;
  mrb_get_args(mrb, "i", &pid);
  sid = getsid((pid_t)pid);
  if (sid < 0) mrb_sys_fail(mrb, "getsid");
  return mrb_int_value(mrb, (mrb_int)sid);
}

static mrb_value
fs_getpgid(mrb_state* mrb, mrb_value self) {
  mrb_int pid;
  pid_t pgid;
  mrb_get_args(mrb, "i", &pid);
  pgid = getpgid((pid_t)pid);
  if (pgid < 0) mrb_sys_fail(mrb, "getpgid");
  return mrb_int_value(mrb, (mrb_int)pgid);
}

/* One non-blocking reap attempt over every child of the test process.
 * Returns the reaped pid, or nil when there was nothing to reap (no
 * children at all, ECHILD, or children but none finished yet, status 0) —
 * both read the same way for RM2.spawn_detached's zombie test: either
 * answer proves nothing was left behind for the caller to clean up. */
static mrb_value
fs_wait_any_nohang(mrb_state* mrb, mrb_value self) {
  int status;
  pid_t r = waitpid(-1, &status, WNOHANG);
  if (r <= 0) return mrb_nil_value();
  return mrb_int_value(mrb, (mrb_int)r);
}

void
mrb_mruby_rm2_gem_test(mrb_state* mrb) {
  struct RClass* rm2 = mrb_module_get(mrb, "RM2");
  struct RClass* ts = mrb_define_module_under(mrb, rm2, "TestServer");
  mrb_define_class_method(mrb, ts, "start", fs_start, MRB_ARGS_NONE());
  mrb_define_class_method(mrb, ts, "stop", fs_stop, MRB_ARGS_NONE());
  mrb_define_class_method(mrb, ts, "log_path", fs_log_path, MRB_ARGS_NONE());
  mrb_define_class_method(mrb, ts, "make_fifo", fs_make_fifo, MRB_ARGS_NONE());
  mrb_define_class_method(mrb, ts, "pack_events", fs_pack_events,
                          MRB_ARGS_REQ(1));
  mrb_define_class_method(mrb, ts, "last_open_input", fs_last_open_input,
                          MRB_ARGS_NONE());
  mrb_define_class_method(mrb, ts, "start_control", fs_start_control,
                          MRB_ARGS_NONE());
  mrb_define_class_method(mrb, ts, "stop_control", fs_stop_control,
                          MRB_ARGS_NONE());
  mrb_define_class_method(mrb, ts, "last_control_request",
                          fs_last_control_request, MRB_ARGS_NONE());
  mrb_define_class_method(mrb, ts, "raise_signal", fs_raise_signal,
                          MRB_ARGS_REQ(1));
  mrb_define_class_method(mrb, ts, "getsid", fs_getsid, MRB_ARGS_REQ(1));
  mrb_define_class_method(mrb, ts, "getpgid", fs_getpgid, MRB_ARGS_REQ(1));
  mrb_define_class_method(mrb, ts, "wait_any_nohang", fs_wait_any_nohang,
                          MRB_ARGS_NONE());
}
