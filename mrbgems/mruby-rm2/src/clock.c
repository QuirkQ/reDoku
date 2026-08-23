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
 *
 * CLOCK_MONOTONIC does not advance while the machine is suspended to RAM,
 * so "how long ago did the pen leave the glass" measures awake time. For
 * every interval this gem measures that is the wanted answer, but it is not
 * what "milliseconds forward" would lead you to assume.
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
  /* Masked to 31 bits rather than cast straight down. ms cannot be negative
   * (the epoch is the first reading and the clock only moves forward), but
   * it does exceed INT32_MAX after 24.8 days of process life, and int64 ->
   * int32 is IMPLEMENTATION-DEFINED past that in C99, not wrapping by
   * guarantee. The mask says what happens instead of asking the compiler:
   * the result is always in 0..INT32_MAX, so it fits any mrb_int exactly,
   * on the device's 32-bit build and the host's 64-bit one alike. The cost
   * is one interval expiring early every 24.8 days, which the only
   * supported use — subtracting two readings — already handles by reading a
   * negative difference as "long expired" (App#touch_suppressed?). */
  return mrb_int_value(mrb, (mrb_int)(ms & 0x7fffffff));
}

void
rm2_clock_init(mrb_state* mrb, struct RClass* rm2) {
  mrb_define_module_function(mrb, rm2, "monotonic_ms", rm2_s_monotonic_ms,
                             MRB_ARGS_NONE());
}
