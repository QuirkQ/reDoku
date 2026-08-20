/* mrbgems/mruby-rm2/src/gem.c */
#include <mruby.h>

void
mrb_mruby_rm2_gem_init(mrb_state* mrb) {
  mrb_define_module(mrb, "RM2");
}

void
mrb_mruby_rm2_gem_final(mrb_state* mrb) {
}
