/* mrbgems/mruby-rm2/src/control.c
 *
 * rm2fb control socket (PLAN.md §3): an AF_UNIX SOCK_DGRAM RPC at
 * /var/run/rm2fb.control.sock, one `Request{int32 type; int32 pid}` out and
 * one reply back. Verified against rM2-stuff libs/rm2fb/ControlSocket.cpp.
 *
 * The socket must be bound before it can receive a reply: the server
 * answers with sendto() to our address, and an unbound datagram socket has
 * none. bind() with an addrlen of just the family autobinds an abstract
 * name, which is what rM2-stuff's own ControlClient does.
 *
 * A live display client must never switch_to() away from itself: the server
 * SIGSTOPs the whole process group of the client it demotes, so the caller
 * would freeze inside this call. Returning the screen to xochitl is done by
 * closing the display connection and exiting.
 */
#include "rm2.h"

#include <mruby.h>
#include <mruby/array.h>
#include <mruby/class.h>
#include <mruby/error.h>
#include <mruby/hash.h>
#include <mruby/string.h>

#include <errno.h>
#include <stdint.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <sys/un.h>
#include <unistd.h>

#define CTL_GET_CLIENTS 0
#define CTL_SWITCH_TO 2
#define CTL_MAX_CLIENTS 64
#define CTL_TIMEOUT_SEC 2

typedef struct {
  int32_t type;
  int32_t pid;
} control_req; /* 8 bytes on both target ABIs */

/* Mirrors ControlInterface::Client. */
typedef struct {
  int32_t pid;
  uint8_t active;
  uint8_t pad[3];
  int32_t width, height, pixel_format;
  char name[32];
} control_client; /* 52 bytes on both target ABIs */

typedef char rm2_control_req_size_check[(sizeof(control_req) == 8) ? 1 : -1];
typedef char rm2_control_client_size_check[(sizeof(control_client) == 52) ? 1 : -1];

/* Connected, autobound, read-timeout-armed control socket, or -1 with errno
 * set. A timeout matters because the server simply does not answer some
 * failures. */
static int
control_connect(const char* path) {
  struct sockaddr_un self, addr;
  struct timeval tv;
  int sock = socket(AF_UNIX, SOCK_DGRAM, 0);
  if (sock < 0) return -1;

  memset(&self, 0, sizeof(self));
  self.sun_family = AF_UNIX;
  if (bind(sock, (struct sockaddr*)&self, (socklen_t)sizeof(sa_family_t)) < 0)
    goto fail;

  memset(&addr, 0, sizeof(addr));
  addr.sun_family = AF_UNIX;
  if (strlen(path) >= sizeof(addr.sun_path)) {
    errno = ENAMETOOLONG;
    goto fail;
  }
  strcpy(addr.sun_path, path);
  if (connect(sock, (struct sockaddr*)&addr, sizeof(addr)) < 0) goto fail;

  tv.tv_sec = CTL_TIMEOUT_SEC;
  tv.tv_usec = 0;
  if (setsockopt(sock, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv)) < 0) goto fail;
  return sock;

fail: {
  int e = errno;
  close(sock);
  errno = e;
  return -1;
}
}

/* Raise a SystemCallError without letting close() clobber errno. */
static void
fail_close(mrb_state* mrb, int sock, const char* msg) {
  int e = errno;
  close(sock);
  errno = e;
  mrb_sys_fail(mrb, msg);
}

static const char*
control_path(mrb_state* mrb) {
  const char* path = "/var/run/rm2fb.control.sock";
  mrb_get_args(mrb, "|z", &path);
  return path;
}

static mrb_value
rm2_control_s_clients(mrb_state* mrb, mrb_value klass) {
  const char* path = control_path(mrb);
  char buf[sizeof(int32_t) + CTL_MAX_CLIENTS * sizeof(control_client)];
  control_req req;
  int sock;
  ssize_t n;
  int32_t count, i;
  mrb_value out;

  sock = control_connect(path);
  if (sock < 0) mrb_sys_fail(mrb, "connect to rm2fb control socket");

  req.type = CTL_GET_CLIENTS;
  req.pid = 0;
  if (send(sock, &req, sizeof(req), MSG_NOSIGNAL) < 0)
    fail_close(mrb, sock, "send GetClients");
  n = recv(sock, buf, sizeof(buf), 0);
  if (n < 0) fail_close(mrb, sock, "read GetClients reply");
  close(sock);

  if ((size_t)n < sizeof(int32_t))
    mrb_raise(mrb, E_RUNTIME_ERROR, "short GetClients reply");

  memcpy(&count, buf, sizeof(count));
  /* Bound the count before it is ever multiplied: on the 32-bit device ABI
   * count * sizeof(control_client) would wrap for a large enough count and
   * a wrapped product passes any length check. Anything above the records
   * this buffer can hold is unparseable regardless of the datagram. */
  if (count < 0 || count > CTL_MAX_CLIENTS)
    mrb_raise(mrb, E_RUNTIME_ERROR, "implausible GetClients client count");
  if ((size_t)n < sizeof(int32_t) + (size_t)count * sizeof(control_client))
    mrb_raise(mrb, E_RUNTIME_ERROR, "truncated GetClients reply");

  out = mrb_ary_new_capa(mrb, count);
  for (i = 0; i < count; i++) {
    control_client c;
    mrb_value h = mrb_hash_new_capa(mrb, 3);
    size_t len;

    memcpy(&c, buf + sizeof(int32_t) + (size_t)i * sizeof(control_client),
           sizeof(c));
    /* name[] is not required to be terminated. */
    for (len = 0; len < sizeof(c.name) && c.name[len] != '\0'; len++) {}

    mrb_hash_set(mrb, h, mrb_symbol_value(mrb_intern_lit(mrb, "pid")),
                 mrb_int_value(mrb, c.pid));
    mrb_hash_set(mrb, h, mrb_symbol_value(mrb_intern_lit(mrb, "active")),
                 mrb_bool_value(c.active != 0));
    mrb_hash_set(mrb, h, mrb_symbol_value(mrb_intern_lit(mrb, "name")),
                 mrb_str_new(mrb, c.name, len));
    mrb_ary_push(mrb, out, h);
  }
  return out;
}

static mrb_value
rm2_control_s_switch_to(mrb_state* mrb, mrb_value klass) {
  mrb_int pid;
  const char* path = "/var/run/rm2fb.control.sock";
  control_req req;
  int sock;
  uint8_t ok = 0;
  ssize_t n;

  mrb_get_args(mrb, "i|z", &pid, &path);

  sock = control_connect(path);
  if (sock < 0) mrb_sys_fail(mrb, "connect to rm2fb control socket");

  req.type = CTL_SWITCH_TO;
  req.pid = (int32_t)pid;
  if (send(sock, &req, sizeof(req), MSG_NOSIGNAL) < 0)
    fail_close(mrb, sock, "send SwitchTo");
  n = recv(sock, &ok, sizeof(ok), 0);
  if (n < 0) fail_close(mrb, sock, "read SwitchTo reply");
  close(sock);
  return mrb_bool_value(n == 1 && ok != 0);
}

void
rm2_control_init(mrb_state* mrb, struct RClass* rm2) {
  struct RClass* cls = mrb_define_module_under(mrb, rm2, "Control");
  mrb_define_module_function(mrb, cls, "clients", rm2_control_s_clients,
                             MRB_ARGS_OPT(1));
  mrb_define_module_function(mrb, cls, "switch_to", rm2_control_s_switch_to,
                             MRB_ARGS_ARG(1, 1));
  mrb_define_const(mrb, cls, "SOCKET_PATH",
                   mrb_str_new_lit(mrb, "/var/run/rm2fb.control.sock"));
}
