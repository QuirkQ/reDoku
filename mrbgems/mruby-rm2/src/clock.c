/* mrbgems/mruby-rm2/src/clock.c
 *
 * RM2.monotonic_ms — milliseconds on a clock that only ever moves forward.
 * Only DIFFERENCES between two readings mean anything; the epoch is
 * deliberately unspecified.
 *
 * Why not Time.now: the game measures short intervals (how long ago the pen
 * left the glass, and later how long a cell has been idle), and a wall clock
 * steps — NTP, a USB time sync, a timezone change — which would turn a
 * half-second cooldown into hours, or into nothing. CLOCK_MONOTONIC cannot
 * step. It also keeps this gem's dependency list as it is, and stays whole:
 * counting milliseconds needs no mrb_float.
 *
 * The epoch is the first reading rather than boot, because mrb_int is 32-bit
 * on the armv7 device: uptime in milliseconds overflows int32 after 24.8
 * days, which a reMarkable reaches without trying, while a GAME process
 * living that long is another matter. A caller that subtracts two readings
 * (the only supported use) then sees such a wrap as one interval expiring
 * early, not as a deadline that can never be reached.
 */
#include "rm2.h"

#include <mruby/error.h>

#include <stdint.h>
#include <time.h>

static int g_base_valid = 0;
static struct timespec g_base;

static mrb_value
rm2_s_monotonic_ms(mrb_state* mrb, mrb_value self) {
  struct timespec now;
  int64_t ms;

  if (clock_gettime(CLOCK_MONOTONIC, &now) < 0)
    mrb_sys_fail(mrb, "read the monotonic clock");
  if (!g_base_valid) {
    g_base = now;
    g_base_valid = 1;
  }
  /* tv_sec is 32-bit on the device ABI, so widen before multiplying. The
   * nanosecond difference may be negative; adding a negative millisecond
   * count to a whole second is still the right total. */
  ms = (int64_t)(now.tv_sec - g_base.tv_sec) * 1000 +
       (int64_t)(now.tv_nsec - g_base.tv_nsec) / 1000000;
  return mrb_int_value(mrb, (mrb_int)ms);
}

void
rm2_clock_init(mrb_state* mrb, struct RClass* rm2) {
  mrb_define_module_function(mrb, rm2, "monotonic_ms", rm2_s_monotonic_ms,
                             MRB_ARGS_NONE());
}
