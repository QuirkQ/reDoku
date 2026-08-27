/* mrbgems/mruby-rm2/src/signals.c
 *
 * Signal handling for a long-lived rm2fb client. Handlers only set flags —
 * the Ruby event loop polls them, so nothing async touches the mruby VM.
 *
 * The server SIGSTOPs the process group of every client that is not front
 * and SIGCONTs it when it comes back, re-flashing its buffer first; we
 * still want to know, because a full redraw is the cheap way to be sure
 * what is on the panel matches what we think is there.
 *
 * SIGHUP has nothing to do with a display client's own lifecycle — the
 * watcher (`redoku --watch`, PLAN.md §10) has no controlling terminal to
 * hang up, so it repurposes SIGHUP the way a long-lived daemon
 * conventionally does: "re-read your config," delivered by `systemctl
 * reload` or a plain `kill -HUP`. It is handled here rather than in a
 * watcher-only file because it is the same kind of flag as the three
 * above — set by a handler, polled from Ruby — and this file is where
 * that pattern already lives.
 *
 * Handlers are installed WITHOUT SA_RESTART on purpose: a signal should cut
 * a blocking poll() short so the loop gets a turn to look at these flags.
 */
#include "rm2.h"

#include <mruby.h>
#include <mruby/class.h>
#include <mruby/error.h>

#include <signal.h>
#include <string.h>

static volatile sig_atomic_t g_terminated = 0;
static volatile sig_atomic_t g_resumed = 0;
static volatile sig_atomic_t g_reload = 0;

static void
on_terminate(int sig) {
  (void)sig;
  g_terminated = 1;
}

static void
on_cont(int sig) {
  (void)sig;
  g_resumed = 1;
}

static void
on_hup(int sig) {
  (void)sig;
  g_reload = 1;
}

static mrb_value
rm2_s_setup_signals(mrb_state* mrb, mrb_value self) {
  struct sigaction term, cont, hup, sigpipe;

  memset(&term, 0, sizeof(term));
  term.sa_handler = on_terminate;
  if (sigaction(SIGTERM, &term, NULL) < 0 ||
      sigaction(SIGINT, &term, NULL) < 0)
    mrb_sys_fail(mrb, "install termination handler");

  memset(&cont, 0, sizeof(cont));
  cont.sa_handler = on_cont;
  if (sigaction(SIGCONT, &cont, NULL) < 0)
    mrb_sys_fail(mrb, "install SIGCONT handler");

  memset(&hup, 0, sizeof(hup));
  hup.sa_handler = on_hup;
  if (sigaction(SIGHUP, &hup, NULL) < 0)
    mrb_sys_fail(mrb, "install SIGHUP handler");

  /* A dead server must surface as EPIPE from send(), not as a signal. */
  memset(&sigpipe, 0, sizeof(sigpipe));
  sigpipe.sa_handler = SIG_IGN;
  if (sigaction(SIGPIPE, &sigpipe, NULL) < 0)
    mrb_sys_fail(mrb, "ignore SIGPIPE");

  return mrb_nil_value();
}

/* Sticky: once asked to quit, always quitting. */
static mrb_value
rm2_s_terminated_p(mrb_state* mrb, mrb_value self) {
  return mrb_bool_value(g_terminated != 0);
}

/* Consumed on read: each SIGCONT is reported exactly once. */
static mrb_value
rm2_s_resumed_p(mrb_state* mrb, mrb_value self) {
  int was = g_resumed;
  g_resumed = 0;
  return mrb_bool_value(was != 0);
}

/* Consumed on read, the same as resumed? and for the same reason: "config
 * changed, re-read it" is not a fact that becomes permanently true the
 * first time it happens (unlike terminated?, which is sticky because
 * quitting only ever needs to be noticed once) — a second SIGHUP later in
 * the process's life must be seen too. */
static mrb_value
rm2_s_reload_p(mrb_state* mrb, mrb_value self) {
  int was = g_reload;
  g_reload = 0;
  return mrb_bool_value(was != 0);
}

void
rm2_signals_init(mrb_state* mrb, struct RClass* rm2) {
  mrb_define_module_function(mrb, rm2, "setup_signals", rm2_s_setup_signals,
                             MRB_ARGS_NONE());
  mrb_define_module_function(mrb, rm2, "terminated?", rm2_s_terminated_p,
                             MRB_ARGS_NONE());
  mrb_define_module_function(mrb, rm2, "resumed?", rm2_s_resumed_p,
                             MRB_ARGS_NONE());
  mrb_define_module_function(mrb, rm2, "reload?", rm2_s_reload_p,
                             MRB_ARGS_NONE());
}
