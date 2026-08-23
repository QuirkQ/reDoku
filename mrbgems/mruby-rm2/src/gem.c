#include "rm2.h"

void
mrb_mruby_rm2_gem_init(mrb_state* mrb) {
  struct RClass* rm2 = mrb_define_module(mrb, "RM2");
  /* Input first: rm2_input_new resolves RM2::Input by class lookup, and
   * Display#open_input calls it. */
  rm2_input_init(mrb, rm2);
  rm2_display_init(mrb, rm2);
  rm2_control_init(mrb, rm2);
  rm2_signals_init(mrb, rm2);
  rm2_clock_init(mrb, rm2);
}

void
mrb_mruby_rm2_gem_final(mrb_state* mrb) {
}
