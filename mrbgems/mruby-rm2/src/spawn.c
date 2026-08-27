/* mrbgems/mruby-rm2/src/spawn.c
 *
 * RM2.spawn_detached(path, *argv) — launch a process that must survive
 * whatever happens to its caller's process group. This exists for exactly
 * one caller: the hijack watcher (`redoku --watch`, PLAN.md §10) spawning
 * the game at /home/root/redoku/bin/redoku.
 *
 * Why this needs its own primitive instead of mruby-io's IO.popen: popen's
 * child stays in the parent's process group, and rm2fb SIGSTOPs the whole
 * process group of any display client it demotes (control.c's header,
 * README). The game IS such a client the moment its own Init lands — a
 * demotion aimed at it would freeze the watcher too, since they'd share a
 * group. The child must be in a session and process group of its own,
 * which needs setsid(), which needs a fork mruby's default gembox has no
 * primitive for either.
 *
 * The double fork below is the standard, well-worn way to get there
 * without ever leaving a zombie under the caller:
 *
 *   caller -> fork -> intermediate -> setsid() -> fork -> grandchild -> exec
 *
 * The intermediate calls setsid() BEFORE its own fork so the grandchild is
 * born already inside the new session/group, then exits at once. The
 * caller waitpid()s the intermediate immediately (it is short-lived by
 * construction, so this never blocks for long), which is the only reap
 * this function ever does. The grandchild — the process that becomes the
 * game — is never the caller's own child to begin with: the instant the
 * intermediate exits, the kernel reparents it to init (or the nearest
 * subreaper), whose job it is to reap it whenever it eventually exits.
 * "The watcher never has to reap" falls out of that reparenting, not out
 * of anything this function keeps doing after it returns.
 *
 * Two pipes carry the two things the caller needs back across three
 * processes, each closed on successful use so a blocking read() on the
 * other end sees EOF instead of hanging forever:
 *
 *   pidpipe — the intermediate writes the grandchild's pid here right
 *     after the second fork succeeds. Silence (EOF with nothing read)
 *     means that fork — or the setsid() before it — failed instead; the
 *     intermediate's errno for that is waiting on errpipe.
 *   errpipe — FD_CLOEXEC on its write end, which is what makes it useful:
 *     a successful execve() in the grandchild closes it for free, so EOF
 *     on this pipe with no bytes read means "exec worked" without the
 *     grandchild having to say so. If exec fails instead, the grandchild
 *     writes its own errno here before _exit()ing — the known way to get
 *     an errno across a fork (there is no shared memory to leave it in).
 *
 * Blocking on errpipe waits only for the fork/exec handoff — a handful of
 * syscalls — never for the spawned program to finish running.
 *
 * Stdio is left exactly as the grandchild inherits it: no dup2, no close.
 * A systemd-run watcher's journald capture is stdout/stderr redirected at
 * the unit level, and inheriting is what makes that also cover the game.
 */
#include "rm2.h"

#include <mruby/array.h>
#include <mruby/error.h>
#include <mruby/string.h>

#include <errno.h>
#include <fcntl.h>
#include <string.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <unistd.h>

/* argv slots, including argv[0] (the path) and the NULL terminator — a
 * `redoku --watch` invocation needs at most a couple, this is headroom,
 * not a guess at a real ceiling. Bounded for the same reason RM2_MAX_WAIT
 * is in input.c: an unbounded rest-args count would size a stack array off
 * whatever the Ruby caller happens to pass. */
#define RM2_SPAWN_MAX_ARGV 32

/* Reads up to len bytes, retrying on EINTR, stopping (without raising) on
 * any other error the same as on EOF: a short result already means
 * "nothing more is coming," which is all either call site below needs to
 * know. Returns how many bytes actually arrived (0..len). */
static size_t
spawn_read_all(int fd, void* buf, size_t len) {
  char* p = (char*)buf;
  size_t got = 0;
  while (got < len) {
    ssize_t n = read(fd, p + got, len - got);
    if (n < 0) {
      if (errno == EINTR) continue;
      break;
    }
    if (n == 0) break;
    got += (size_t)n;
  }
  return got;
}

/* Child-side only: write, retrying on EINTR, then _exit. Never returns.
 * len is always sizeof(int) or sizeof(pid_t) here, well under PIPE_BUF, so
 * one successful write() call always carries the whole thing — the retry
 * loop exists for EINTR, not for reassembling a split write. */
static void
spawn_report_and_exit(int fd, const void* buf, size_t len, int code) {
  const char* p = (const char*)buf;
  size_t sent = 0;
  while (sent < len) {
    ssize_t n = write(fd, p + sent, len - sent);
    if (n < 0) {
      if (errno == EINTR) continue;
      break; /* nothing left to do about it; about to _exit anyway */
    }
    sent += (size_t)n;
  }
  _exit(code);
}

static mrb_value
rm2_s_spawn_detached(mrb_state* mrb, mrb_value self) {
  const char* path;
  const mrb_value* rest;
  mrb_int restc, i;
  char* argv[RM2_SPAWN_MAX_ARGV];
  int pidpipe[2], errpipe[2];
  pid_t mid, gpid = 0;
  size_t got;

  mrb_get_args(mrb, "z*", &path, &rest, &restc);
  if (restc > RM2_SPAWN_MAX_ARGV - 2)
    mrb_raisef(mrb, E_ARGUMENT_ERROR, "at most %i extra arguments",
               (mrb_int)(RM2_SPAWN_MAX_ARGV - 2));

  argv[0] = (char*)path;
  for (i = 0; i < restc; i++) {
    if (!mrb_string_p(rest[i]))
      mrb_raise(mrb, E_TYPE_ERROR, "spawn_detached arguments must be strings");
    /* Copies into a fresh, NUL-terminated buffer and raises ArgumentError
     * on an embedded NUL — the same check "z" applies to path, and for the
     * same reason: a NUL inside an argv string would silently truncate
     * what the spawned process sees versus what the caller asked for. */
    argv[i + 1] = mrb_str_to_cstr(mrb, rest[i]);
  }
  argv[restc + 1] = NULL;

  if (pipe(pidpipe) < 0) mrb_sys_fail(mrb, "create spawn pid pipe");
  if (pipe(errpipe) < 0) {
    int e = errno;
    close(pidpipe[0]);
    close(pidpipe[1]);
    errno = e;
    mrb_sys_fail(mrb, "create spawn error pipe");
  }
  /* Both write ends get CLOEXEC, not just errpipe's: the grandchild is
   * forked from the intermediate BEFORE the intermediate writes to
   * pidpipe and exits, so without this it would inherit pidpipe's write
   * end too and carry a pointless open pipe fd for its entire life once
   * exec replaces its image — exactly the kind of leak into the game
   * process this shim exists to not cause. */
  if (fcntl(pidpipe[1], F_SETFD, FD_CLOEXEC) < 0 ||
      fcntl(errpipe[1], F_SETFD, FD_CLOEXEC) < 0) {
    int e = errno;
    close(pidpipe[0]);
    close(pidpipe[1]);
    close(errpipe[0]);
    close(errpipe[1]);
    errno = e;
    mrb_sys_fail(mrb, "set spawn pipes close-on-exec");
  }

  mid = fork();
  if (mid < 0) {
    int e = errno;
    close(pidpipe[0]);
    close(pidpipe[1]);
    close(errpipe[0]);
    close(errpipe[1]);
    errno = e;
    mrb_sys_fail(mrb, "fork spawn-detached intermediate");
  }

  if (mid == 0) {
    /* Intermediate child. From here to _exit()/execve() only
     * async-signal-safe calls are allowed: this process still shares the
     * parent's mruby heap and GC state (copy-on-write) and must not touch
     * either — same discipline test/fake_server.c's fs_serve follows after
     * its own fork(). */
    pid_t gc;
    close(pidpipe[0]);
    close(errpipe[0]);

    /* Must happen before the second fork: the grandchild inherits
     * whatever session/group is current AT FORK TIME, and the whole point
     * is for it to be born into the new one, not merely moved there
     * later (there would be a window, after birth and before the move,
     * where it still shared the watcher's group). */
    if (setsid() < 0) {
      int e = errno;
      spawn_report_and_exit(errpipe[1], &e, sizeof(e), 127);
    }

    gc = fork();
    if (gc < 0) {
      int e = errno;
      spawn_report_and_exit(errpipe[1], &e, sizeof(e), 127);
    }
    if (gc == 0) {
      execv(path, argv);
      /* execv() only returns on failure. */
      {
        int e = errno;
        spawn_report_and_exit(errpipe[1], &e, sizeof(e), 127);
      }
    }
    /* Report the grandchild's pid, then exit immediately: the parent is
     * about to waitpid() for exactly this process. */
    spawn_report_and_exit(pidpipe[1], &gc, sizeof(gc), 0);
  }

  /* Parent (the watcher). */
  close(pidpipe[1]);
  close(errpipe[1]);

  {
    int status;
    while (waitpid(mid, &status, 0) < 0 && errno == EINTR) {}
  }

  got = spawn_read_all(pidpipe[0], &gpid, sizeof(gpid));
  close(pidpipe[0]);

  if (got != sizeof(gpid)) {
    /* setsid() or the second fork failed before a grandchild ever
     * existed; the intermediate's errno for that is on errpipe. */
    int e = 0;
    size_t egot = spawn_read_all(errpipe[0], &e, sizeof(e));
    close(errpipe[0]);
    if (egot == sizeof(e)) {
      errno = e;
      mrb_sys_fail(mrb, "spawn-detached setup");
    }
    mrb_raise(mrb, E_RUNTIME_ERROR,
              "spawn-detached intermediate exited without reporting a pid "
              "or an error");
  }

  {
    int e = 0;
    size_t egot = spawn_read_all(errpipe[0], &e, sizeof(e));
    close(errpipe[0]);
    if (egot == sizeof(e)) {
      errno = e;
      mrb_sys_fail(mrb, "execv");
    }
    /* Fewer bytes than sizeof(e) — necessarily 0, since a writer only ever
     * sends the whole int in one call — means EOF: FD_CLOEXEC closed the
     * write end for us, so exec succeeded. */
  }

  return mrb_int_value(mrb, (mrb_int)gpid);
}

void
rm2_spawn_init(mrb_state* mrb, struct RClass* rm2) {
  mrb_define_module_function(mrb, rm2, "spawn_detached", rm2_s_spawn_detached,
                             MRB_ARGS_REQ(1) | MRB_ARGS_REST());
}
