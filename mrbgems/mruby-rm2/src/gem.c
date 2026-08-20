#include <mruby.h>
#include <mruby/class.h>

void rm2_display_init(mrb_state* mrb, struct RClass* rm2);

void
mrb_mruby_rm2_gem_init(mrb_state* mrb) {
  struct RClass* rm2 = mrb_define_module(mrb, "RM2");
  rm2_display_init(mrb, rm2);
}

void
mrb_mruby_rm2_gem_final(mrb_state* mrb) {
}
