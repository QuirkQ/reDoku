/* mrbgems/mruby-rm2/test/fake_server.c
 *
 * In-process fake rm2fb server for mrbtest. Speaks the real wire protocol
 * (PLAN.md §3) on a /tmp unix socket: grants a memfd-backed framebuffer on
 * Init and logs every UpdateParams it receives — raw 32-byte structs
 * appended to a log file — so Ruby tests can assert exact bytes.
 *
 * The listening socket is bound in the parent BEFORE forking, so the
 * socket is connectable the moment RM2::TestServer.start returns.
 */
#define _GNU_SOURCE
#include <mruby.h>
#include <mruby/class.h>
#include <mruby/error.h>
#include <mruby/string.h>

#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <sys/wait.h>
#include <unistd.h>

#define FAKE_FB_WIDTH 1404
#define FAKE_FB_HEIGHT 1872
#define FAKE_FB_TOTAL ((size_t)FAKE_FB_WIDTH * FAKE_FB_HEIGHT * 3)

static pid_t server_pid = -1;
static char sock_path[108];
static char log_path[128];

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
  unlink(sock_path);

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
  }
  return mrb_nil_value();
}

static mrb_value
fs_log_path(mrb_state* mrb, mrb_value self) {
  return mrb_str_new_cstr(mrb, log_path);
}

void
mrb_mruby_rm2_gem_test(mrb_state* mrb) {
  struct RClass* rm2 = mrb_module_get(mrb, "RM2");
  struct RClass* ts = mrb_define_module_under(mrb, rm2, "TestServer");
  mrb_define_class_method(mrb, ts, "start", fs_start, MRB_ARGS_NONE());
  mrb_define_class_method(mrb, ts, "stop", fs_stop, MRB_ARGS_NONE());
  mrb_define_class_method(mrb, ts, "log_path", fs_log_path, MRB_ARGS_NONE());
}
