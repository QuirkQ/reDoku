/* mrbgems/mruby-bin-redoku/tools/redoku/redoku.c
 *
 * The redoku executable. All it does is boot an mruby VM (the game's Ruby
 * is compiled into libmruby by the mruby-redoku gem) and hand argv to
 * Redoku.main, whose return value becomes the exit status.
 */
#include <mruby.h>
#include <mruby/array.h>
#include <mruby/class.h>
#include <mruby/string.h>
#include <mruby/value.h>

#include <stdio.h>
#include <stdlib.h>

int
main(int argc, char** argv) {
  mrb_state* mrb = mrb_open();
  mrb_value args, result;
  int status = 0;
  int i;

  if (mrb == NULL) {
    fprintf(stderr, "redoku: could not start the mruby VM\n");
    return 1;
  }

  args = mrb_ary_new_capa(mrb, argc > 1 ? argc - 1 : 0);
  for (i = 1; i < argc; i++)
    mrb_ary_push(mrb, args, mrb_str_new_cstr(mrb, argv[i]));

  result = mrb_funcall(mrb, mrb_obj_value(mrb_module_get(mrb, "Redoku")),
                       "main", 1, args);

  if (mrb->exc != NULL) {
    mrb_print_error(mrb);
    status = 1;
  }
  else if (mrb_integer_p(result)) {
    status = (int)mrb_integer(result);
  }

  mrb_close(mrb);
  return status;
}
