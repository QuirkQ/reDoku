/* mrbgems/mruby-rm2/src/rm2.h
 *
 * Internal declarations shared between this gem's C sources. Not a public
 * header: none of this is visible to Ruby except through the classes each
 * translation unit defines.
 */
#ifndef REDOKU_RM2_H
#define REDOKU_RM2_H

#include <mruby.h>
#include <mruby/class.h>

/* Per-source registration, called from mrb_mruby_rm2_gem_init. */
void rm2_display_init(mrb_state* mrb, struct RClass* rm2);
void rm2_input_init(mrb_state* mrb, struct RClass* rm2);

/* Wraps an already-open evdev fd in a fresh RM2::Input. Takes ownership:
 * the object closes the fd. Defined in input.c, called from display.c's
 * open_input, which is the only way to obtain such an fd. */
mrb_value rm2_input_new(mrb_state* mrb, int fd);

#endif /* REDOKU_RM2_H */
