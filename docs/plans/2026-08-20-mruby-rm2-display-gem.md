# mruby-rm2 Display Gem Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A working `mruby-rm2` mrbgem whose `RM2::Display` class speaks the rm2fb display-server wire protocol, proven by byte-exact tests against a fake server, plus the Docker build pipeline that produces both a Linux host `mrbtest` and an armv7 `bin/mruby` for the reMarkable 2.

**Architecture:** Everything is an mrbgem. `mruby-rm2` follows the canonical layout: C protocol code in `src/`, Ruby sugar in `mrblib/`, mrbtest suites in `test/`, and a fake rm2fb server as C test scaffolding via mruby's `mrb_<gem>_gem_test` hook (the same pattern core's mruby-io uses to test its socket code). mruby itself is a sibling checkout (`../mruby`); builds run mruby's own rake inside a Docker container with `MRUBY_CONFIG`/`MRUBY_BUILD_DIR` pointing into this repo.

**Tech Stack:** mruby 4.0.0 (sibling checkout), Docker (`ghcr.io/toltec-dev/base:v4.0`, linux/amd64), GNU make, C (gnu99), the rm2fb unix-socket protocol.

**Spec:** `PLAN.md` (repo root) — especially §3 (wire protocol), §4 (repo layout), §5 (shim API), §9 (build/test). All protocol constants below were verified against the rM2-stuff fork source at `../rM2-stuff` (`libs/rm2fb/include/rm2fb/Message.h`, `SharedBuffer.h`, `ServerSwtcon.cpp`).

## Global Constraints

- mruby lives at `../mruby` relative to this repo (override with `make MRUBY_DIR=…`). It must report version 4.0.0 (`include/mruby/version.h`: `MRUBY_RELEASE_MAJOR 4`, `MINOR 0`, `TEENY 0`).
- The rM2-stuff fork lives at `../rM2-stuff` — reference only in this plan; nothing builds from it here.
- Docker image base: `ghcr.io/toltec-dev/base:v4.0`, always built and run with `--platform linux/amd64`. Cross toolchain inside it: `/opt/x-tools/arm-remarkable-linux-gnueabihf/bin/arm-remarkable-linux-gnueabihf-{gcc,ar}` (verified in Task 1; if the path differs, fix `build_config.rb`, not the image).
- Nothing is installed on the Mac. Every build and test runs inside the container. All build artifacts land in `build/` (gitignored).
- Wire protocol is little-endian, x86-64 and ARM EABI struct layout (4-byte alignment — the structs below have no hidden padding). Framebuffer: 1404×1872, RGB565 plane (2 B/px) followed by a gray plane (1 B/px); total mmap size 1404×1872×3 = 7,884,864 bytes.
- Message framing: `int32 tag` + raw struct. Tags: `Init=0`, `UpdateParams=2`. `Init` payload is 16 bytes (`bool ownSwtcon` + 3 pad + `int32 width,height,pixelFormat`); reply is 12 bytes (granted `width,height,pixelFormat`) followed by a 1-payload-byte `sendmsg` carrying the framebuffer fd via `SCM_RIGHTS`. `UpdateParams` payload is 32 bytes (`int32 y1,x1,y2,x2,flags,waveform; float temperature; int32 extraMode` — y first, corners **inclusive**); reply is 1 bool byte (ack).
- Waveform values sent on the wire are Linux ioctl constants OR'd with `0xf000`: `DU=0xf001`, `GC16=0xf002`, `GL16=0xf003`, `A2=0xf004`. Flags: `SYNC=1`, `FAST_DRAW=2`. (The rM2-stuff `SwtconWaveformMode` enum where A2=6 is the server's *internal* LUT index — never send those.)
- mruby compiles gem C code with `-std=gnu99`. No C11-only constructs (`_Static_assert`, anonymous unions in APIs).
- gray→RGB565 conversion: `(g>>3) | ((g>>2)<<5) | ((g>>3)<<11)`; white 255→`0xFFFF`, black 0→`0x0000`, 128→`0x8410`.
- TDD: within each task, write the failing test, watch it fail, implement, watch it pass. Commit at the end of every task.
- The first `make test` compiles all of mruby (both targets from Task 2 on) — expect several minutes; later runs are incremental.

---

### Task 1: Docker build environment, Makefile, host build target

Proves the toolchain end-to-end before any of our code exists: mruby's own
test suite must pass inside the container.

**Files:**
- Create: `docker/Dockerfile`
- Create: `Makefile`
- Create: `build_config.rb`
- Create: `.gitignore`

**Interfaces:**
- Consumes: sibling mruby checkout at `../mruby`.
- Produces: `make image` / `make test` / `make build` / `make shell` / `make clean`; container image `redoku-build`; mruby build output in `build/host/`. Later tasks add `conf.gem` lines to `build_config.rb` and a cross target.

- [ ] **Step 1: Write the Dockerfile**

```dockerfile
# docker/Dockerfile
# Build environment: Toltec's reMarkable cross toolchain plus what mruby's
# rake-based build needs on the host side (CRuby, native gcc, bison/gperf
# for a git checkout of mruby).
FROM ghcr.io/toltec-dev/base:v4.0

RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential ruby rake bison gperf git file \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /mruby
```

- [ ] **Step 2: Write the Makefile**

```makefile
# Makefile — every target is a thin Docker wrapper; nothing runs on the Mac.
IMAGE     := redoku-build
MRUBY_DIR ?= ../mruby
PLATFORM  := linux/amd64

DOCKER_RUN := docker run --rm --platform $(PLATFORM) \
	-v $(CURDIR):/work \
	-v $(abspath $(MRUBY_DIR)):/mruby \
	-w /mruby $(IMAGE)

RAKE := rake MRUBY_CONFIG=/work/build_config.rb MRUBY_BUILD_DIR=/work/build

.PHONY: image build test shell clean

image:
	docker build --platform $(PLATFORM) -t $(IMAGE) docker

build: image
	$(DOCKER_RUN) $(RAKE)

test: image
	$(DOCKER_RUN) $(RAKE) test

shell: image
	docker run --rm -it --platform $(PLATFORM) \
		-v $(CURDIR):/work \
		-v $(abspath $(MRUBY_DIR)):/mruby \
		-w /mruby $(IMAGE) bash

clean:
	rm -rf build
```

(Recipe lines are tabs, not spaces.)

- [ ] **Step 3: Write the host-only build config**

```ruby
# build_config.rb — mruby build configuration for reDoku.
# Run from the mruby checkout (the container mounts it at /mruby):
#   rake MRUBY_CONFIG=/work/build_config.rb MRUBY_BUILD_DIR=/work/build

# Host build: runs inside the Linux build container; executes mrbtest.
MRuby::Build.new do |conf|
  conf.toolchain :gcc
  conf.gembox 'default'
  conf.enable_debug
  conf.enable_test
end
```

- [ ] **Step 4: Write .gitignore**

```gitignore
build/
```

- [ ] **Step 5: Build the image and verify the cross toolchain location**

Run: `make image`
Then: `docker run --rm --platform linux/amd64 redoku-build ls /opt/x-tools/`
Expected: a directory named `arm-remarkable-linux-gnueabihf`. Then:
`docker run --rm --platform linux/amd64 redoku-build ls /opt/x-tools/arm-remarkable-linux-gnueabihf/bin/ | head`
Expected: `arm-remarkable-linux-gnueabihf-gcc`, `…-ar`, etc. If the triplet
or path differs, note the real one — Task 2 hardcodes it in `build_config.rb`.

- [ ] **Step 6: Run mruby's own test suite in the container**

Run: `make test`
Expected: compiles mruby (several minutes), runs `mrbtest`; the summary ends
with `KO: 0` and `Crash: 0`. If `ruby`/`bison` errors appear, the Dockerfile
package list is wrong — fix it there.

- [ ] **Step 7: Commit**

```bash
git add docker/Dockerfile Makefile build_config.rb .gitignore
git commit -m "build: Docker environment + host mruby build with tests"
```

---

### Task 2: armv7 cross-build target

Adds the `rm2` cross target so every `make build` produces device binaries.
The cross-built stock `bin/mruby` interpreter is what Milestone 0 will scp
to the tablet together with the demo script — no custom binary gem needed.

**Files:**
- Modify: `build_config.rb` (append the cross target)

**Interfaces:**
- Consumes: the toolchain path verified in Task 1 Step 5.
- Produces: `build/rm2/bin/mruby` (armv7hf ELF) on every `make build`; a `MRuby::CrossBuild` block named `rm2` that Task 3 adds our gem to.

- [ ] **Step 1: Append the cross target to build_config.rb**

```ruby
# Device build: armv7hf cross-compile for the reMarkable 2 (firmware >= 3.18,
# glibc-compatible per PLAN.md §5). Produces bin/mruby for on-device use.
MRuby::CrossBuild.new('rm2') do |conf|
  conf.toolchain :gcc

  tc = '/opt/x-tools/arm-remarkable-linux-gnueabihf/bin/arm-remarkable-linux-gnueabihf'
  conf.cc do |cc|
    cc.command = "#{tc}-gcc"
    cc.flags << %w[-march=armv7-a -mfpu=neon -mfloat-abi=hard -O2]
  end
  conf.linker do |linker|
    linker.command = "#{tc}-gcc"
  end
  conf.archiver do |archiver|
    archiver.command = "#{tc}-ar"
  end

  conf.gembox 'default'

  # Cross builds select NO platform port by default (lib/mruby/build.rb
  # effective_ports returns [] for MRuby::CrossBuild), which leaves
  # mruby-io/mruby-dir HAL symbols (mrb_hal_io_*, mrb_hal_dir_*) undefined
  # at link time. The device is ARM Linux, so the posix port is correct.
  conf.ports :posix

  conf.build_mrbtest_lib_only
  conf.disable_cxx_exception
end
```

(If Task 1 Step 5 found a different toolchain path, use that in `tc`.)

- [ ] **Step 2: Build**

Run: `make build`
Expected: both targets compile; no link errors. First cross build takes a
few minutes.

- [ ] **Step 3: Verify the binary is armv7**

Run: `file build/rm2/bin/mruby`
Expected output contains: `ELF 32-bit LSB` … `ARM, EABI5` … `dynamically linked`.

Run: `make test`
Expected: still `KO: 0`, `Crash: 0` (host tests run; the cross target only
builds its mrbtest library).

- [ ] **Step 4: Commit**

```bash
git add build_config.rb
git commit -m "build: armv7hf cross target for the reMarkable 2"
```

---

### Task 3: mruby-rm2 gem skeleton

The gem exists, is wired into both targets, defines the `RM2` module from C
and the waveform/flag constants from Ruby — proven by its first mrbtest suite.

**Files:**
- Create: `mrbgems/mruby-rm2/mrbgem.rake`
- Create: `mrbgems/mruby-rm2/src/gem.c`
- Create: `mrbgems/mruby-rm2/mrblib/rm2.rb`
- Create: `mrbgems/mruby-rm2/test/rm2.rb`
- Modify: `build_config.rb` (add `conf.gem` to both targets)

**Interfaces:**
- Consumes: build pipeline from Tasks 1–2.
- Produces: `RM2` module (defined in `mrb_mruby_rm2_gem_init`); constants `RM2::WAVEFORM_FLAG=0xf000`, `RM2::DU=0xf001`, `RM2::GC16=0xf002`, `RM2::GL16=0xf003`, `RM2::A2=0xf004`, `RM2::SYNC=1`, `RM2::FAST_DRAW=2`. Task 4 extends `gem.c` with `rm2_display_init`.

- [ ] **Step 1: Write the gem spec**

```ruby
# mrbgems/mruby-rm2/mrbgem.rake
MRuby::Gem::Specification.new('mruby-rm2') do |spec|
  spec.license = 'MIT'
  spec.author  = 'Quint Pieters'
  spec.summary = 'reMarkable 2 rm2fb display-server client'
end
```

- [ ] **Step 2: Write the C init stub**

```c
/* mrbgems/mruby-rm2/src/gem.c */
#include <mruby.h>

void
mrb_mruby_rm2_gem_init(mrb_state* mrb) {
  mrb_define_module(mrb, "RM2");
}

void
mrb_mruby_rm2_gem_final(mrb_state* mrb) {
}
```

- [ ] **Step 3: Register the gem in both build targets**

In `build_config.rb`, add to the host `MRuby::Build.new` block AND the
`MRuby::CrossBuild.new('rm2')` block, right after their `conf.gembox 'default'`
lines:

```ruby
  conf.gem File.expand_path('mrbgems/mruby-rm2', File.dirname(__FILE__))
```

- [ ] **Step 4: Write the failing constants test**

```ruby
# mrbgems/mruby-rm2/test/rm2.rb
assert('RM2 waveform constants carry the 0xf000 ioctl flag') do
  assert_equal 0xf001, RM2::DU
  assert_equal 0xf002, RM2::GC16
  assert_equal 0xf003, RM2::GL16
  assert_equal 0xf004, RM2::A2
end

assert('RM2 update flag constants') do
  assert_equal 1, RM2::SYNC
  assert_equal 2, RM2::FAST_DRAW
end
```

- [ ] **Step 5: Run tests to verify they fail**

Run: `make test`
Expected: mrbtest reports failures/errors for the two `RM2 …` assertions
(NameError: uninitialized constant) — and nothing else fails.

- [ ] **Step 6: Write the constants**

```ruby
# mrbgems/mruby-rm2/mrblib/rm2.rb
module RM2
  # UpdateParams.waveform on the wire = Linux WAVEFORM_MODE_* constant with
  # the 0xf000 "this is an ioctl constant" flag set; the server translates
  # to its internal LUT (PLAN.md §3).
  WAVEFORM_FLAG = 0xf000
  DU   = 1 | WAVEFORM_FLAG
  GC16 = 2 | WAVEFORM_FLAG
  GL16 = 3 | WAVEFORM_FLAG
  A2   = 4 | WAVEFORM_FLAG

  # UpdateParams.flags bits.
  SYNC      = 1
  FAST_DRAW = 2
end
```

- [ ] **Step 7: Run tests to verify they pass**

Run: `make test`
Expected: `KO: 0`, `Crash: 0`.

- [ ] **Step 8: Commit**

```bash
git add mrbgems/mruby-rm2 build_config.rb
git commit -m "feat: mruby-rm2 gem skeleton with RM2 constants"
```

---

### Task 4: fake rm2fb server + Display.open handshake

The heart of the plan. A forked C fake server (test scaffolding, mruby-io
style) speaks the real protocol; `RM2::Display.open` performs the Init
handshake, receives the framebuffer fd over `SCM_RIGHTS`, and mmaps it.

**Files:**
- Create: `mrbgems/mruby-rm2/test/fake_server.c`
- Create: `mrbgems/mruby-rm2/test/display.rb`
- Create: `mrbgems/mruby-rm2/src/display.c`
- Modify: `mrbgems/mruby-rm2/src/gem.c`
- Modify: `mrbgems/mruby-rm2/mrbgem.rake`

**Interfaces:**
- Consumes: `RM2` module from Task 3.
- Produces:
  - Test scaffold `RM2::TestServer` (only inside mrbtest): `.start → String` (socket path; forks the server), `.stop → nil`, `.log_path → String` (file of concatenated raw 32-byte UpdateParams records).
  - `RM2::Display.open(path = "/var/run/rm2fb.sock") → RM2::Display` (raises `SystemCallError` on connect failure, `RuntimeError` on protocol violation), `#width → 1404`, `#height → 1872`, `#close → nil`, `#closed? → bool`. Any method on a closed display raises `RuntimeError`.
  - C internals for Tasks 5–6: `struct rm2_display { int sock; uint16_t* fb; size_t map_size; int32_t width; int32_t height; }`, helper `get_open_display(mrb, self)`, IO helpers `write_exact`/`read_exact`, and `rm2_display_init(mrb_state*, struct RClass* rm2_module)` called from `gem.c`.

- [ ] **Step 1: Add test dependencies to the gem spec**

Replace `mrbgems/mruby-rm2/mrbgem.rake` with:

```ruby
MRuby::Gem::Specification.new('mruby-rm2') do |spec|
  spec.license = 'MIT'
  spec.author  = 'Quint Pieters'
  spec.summary = 'reMarkable 2 rm2fb display-server client'

  # Tests read the fake server's update log and assert raw wire bytes.
  spec.add_test_dependency('mruby-io',    core: 'mruby-io')
  spec.add_test_dependency('mruby-pack',  core: 'mruby-pack')
  spec.add_test_dependency('mruby-errno', core: 'mruby-errno')
end
```

- [ ] **Step 2: Write the fake server test scaffold**

Because this file lives in `test/` and is C, mruby's build expects it to
define `mrb_mruby_rm2_gem_test` and links it into `mrbtest` only.

```c
/* mrbgems/mruby-rm2/test/fake_server.c
 *
 * In-process fake rm2fb server for mrbtest. Speaks the real wire protocol
 * (PLAN.md §3) on a /tmp unix socket: grants a memfd-backed framebuffer on
 * Init and logs every UpdateParams it receives — raw 32-byte structs
 * appended to a log file — so Ruby tests can assert exact bytes.
 *
 * The listening socket is bound in the parent BEFORE forking, so the
 * socket is connectable the moment RM2::TestServer.start returns.
 */
#define _GNU_SOURCE
#include <mruby.h>
#include <mruby/class.h>
#include <mruby/error.h>
#include <mruby/string.h>

#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <sys/wait.h>
#include <unistd.h>

#define FAKE_FB_WIDTH 1404
#define FAKE_FB_HEIGHT 1872
#define FAKE_FB_TOTAL ((size_t)FAKE_FB_WIDTH * FAKE_FB_HEIGHT * 3)

static pid_t server_pid = -1;
static char sock_path[108];
static char log_path[128];

static int
fs_write_exact(int fd, const void* buf, size_t len) {
  const char* p = (const char*)buf;
  while (len > 0) {
    ssize_t n = write(fd, p, len);
    if (n < 0) {
      if (errno == EINTR) continue;
      return -1;
    }
    p += n;
    len -= (size_t)n;
  }
  return 0;
}

/* Returns 0 on success, 1 on clean EOF before any byte, -1 on error. */
static int
fs_read_exact(int fd, void* buf, size_t len) {
  char* p = (char*)buf;
  size_t got = 0;
  while (got < len) {
    ssize_t n = read(fd, p + got, len - got);
    if (n < 0) {
      if (errno == EINTR) continue;
      return -1;
    }
    if (n == 0) return got == 0 ? 1 : -1;
    got += (size_t)n;
  }
  return 0;
}

static int
fs_send_fd(int sock, int fd) {
  char dummy = 0;
  struct iovec iov;
  union {
    struct cmsghdr align;
    char buf[CMSG_SPACE(sizeof(int))];
  } u;
  struct msghdr msg;
  struct cmsghdr* c;

  iov.iov_base = &dummy;
  iov.iov_len = 1;
  memset(&msg, 0, sizeof(msg));
  msg.msg_iov = &iov;
  msg.msg_iovlen = 1;
  msg.msg_control = u.buf;
  msg.msg_controllen = sizeof(u.buf);
  c = CMSG_FIRSTHDR(&msg);
  c->cmsg_level = SOL_SOCKET;
  c->cmsg_type = SCM_RIGHTS;
  c->cmsg_len = CMSG_LEN(sizeof(int));
  memcpy(CMSG_DATA(c), &fd, sizeof(fd));
  return sendmsg(sock, &msg, 0) == 1 ? 0 : -1;
}

static void
fs_serve(int listen_fd, int log_fd) {
  int client = accept(listen_fd, NULL, NULL);
  if (client < 0) _exit(1);

  for (;;) {
    int32_t tag;
    int r = fs_read_exact(client, &tag, sizeof(tag));
    if (r == 1) _exit(0); /* client closed cleanly between messages */
    if (r < 0) _exit(1);

    if (tag == 0) { /* Init: 16-byte payload */
      char init[16];
      int32_t granted[3] = { FAKE_FB_WIDTH, FAKE_FB_HEIGHT, 0 /* RGB565 */ };
      int fb;
      if (fs_read_exact(client, init, sizeof(init)) != 0) _exit(1);
      fb = memfd_create("rm2fb-test", 0);
      if (fb < 0) _exit(1);
      if (ftruncate(fb, (off_t)FAKE_FB_TOTAL) < 0) _exit(1);
      if (fs_write_exact(client, granted, sizeof(granted)) < 0) _exit(1);
      if (fs_send_fd(client, fb) < 0) _exit(1);
      close(fb); /* client's mmap keeps the memory alive */
    }
    else if (tag == 2) { /* UpdateParams: 32-byte payload */
      char params[32];
      uint8_t ack = 1;
      if (fs_read_exact(client, params, sizeof(params)) != 0) _exit(1);
      if (fs_write_exact(log_fd, params, sizeof(params)) < 0) _exit(1);
      if (fs_write_exact(client, &ack, sizeof(ack)) < 0) _exit(1);
    }
    else {
      _exit(1); /* unknown tag: fail loudly, the test will see a dead server */
    }
  }
}

static mrb_value
fs_start(mrb_state* mrb, mrb_value self) {
  struct sockaddr_un addr;
  int listen_fd, log_fd;
  pid_t pid;

  if (server_pid > 0)
    mrb_raise(mrb, E_RUNTIME_ERROR, "fake rm2fb server already running");

  snprintf(sock_path, sizeof(sock_path), "/tmp/rm2fb-test-%d.sock", (int)getpid());
  snprintf(log_path, sizeof(log_path), "/tmp/rm2fb-test-%d.log", (int)getpid());
  unlink(sock_path);

  log_fd = open(log_path, O_WRONLY | O_CREAT | O_TRUNC, 0644);
  if (log_fd < 0) mrb_sys_fail(mrb, "open update log");

  listen_fd = socket(AF_UNIX, SOCK_STREAM, 0);
  if (listen_fd < 0) {
    close(log_fd);
    mrb_sys_fail(mrb, "socket");
  }
  memset(&addr, 0, sizeof(addr));
  addr.sun_family = AF_UNIX;
  strncpy(addr.sun_path, sock_path, sizeof(addr.sun_path) - 1);
  if (bind(listen_fd, (struct sockaddr*)&addr, sizeof(addr)) < 0 ||
      listen(listen_fd, 1) < 0) {
    close(listen_fd);
    close(log_fd);
    mrb_sys_fail(mrb, "bind/listen fake server socket");
  }

  pid = fork();
  if (pid < 0) {
    close(listen_fd);
    close(log_fd);
    mrb_sys_fail(mrb, "fork fake server");
  }
  if (pid == 0) {
    fs_serve(listen_fd, log_fd);
    _exit(0);
  }
  close(listen_fd);
  close(log_fd);
  server_pid = pid;
  return mrb_str_new_cstr(mrb, sock_path);
}

static mrb_value
fs_stop(mrb_state* mrb, mrb_value self) {
  if (server_pid > 0) {
    kill(server_pid, SIGKILL);
    waitpid(server_pid, NULL, 0);
    server_pid = -1;
    unlink(sock_path);
  }
  return mrb_nil_value();
}

static mrb_value
fs_log_path(mrb_state* mrb, mrb_value self) {
  return mrb_str_new_cstr(mrb, log_path);
}

void
mrb_mruby_rm2_gem_test(mrb_state* mrb) {
  struct RClass* rm2 = mrb_module_get(mrb, "RM2");
  struct RClass* ts = mrb_define_module_under(mrb, rm2, "TestServer");
  mrb_define_class_method(mrb, ts, "start", fs_start, MRB_ARGS_NONE());
  mrb_define_class_method(mrb, ts, "stop", fs_stop, MRB_ARGS_NONE());
  mrb_define_class_method(mrb, ts, "log_path", fs_log_path, MRB_ARGS_NONE());
}
```

- [ ] **Step 3: Write the failing handshake tests**

```ruby
# mrbgems/mruby-rm2/test/display.rb
assert('RM2::Display.open performs the Init handshake and mmaps the buffer') do
  path = RM2::TestServer.start
  begin
    d = RM2::Display.open(path)
    assert_equal 1404, d.width
    assert_equal 1872, d.height
    assert_false d.closed?
    d.close
    assert_true d.closed?
  ensure
    RM2::TestServer.stop
  end
end

assert('RM2::Display.open raises when no server is listening') do
  assert_raise(SystemCallError) do
    RM2::Display.open('/tmp/no-such-rm2fb.sock')
  end
end

assert('RM2::Display raises on use after close') do
  path = RM2::TestServer.start
  begin
    d = RM2::Display.open(path)
    d.close
    assert_raise(RuntimeError) { d.width }
  ensure
    RM2::TestServer.stop
  end
end
```

- [ ] **Step 4: Run tests to verify they fail**

Run: `make test`
Expected: the three `RM2::Display …` assertions fail (NoMethodError:
undefined method 'open' for RM2::Display / NameError). The two constants
suites from Task 3 still pass. If instead the build fails with
`undefined reference to mrb_mruby_rm2_gem_test`, the hook name in
fake_server.c is wrong — it must be exactly that symbol.

- [ ] **Step 5: Implement the display client**

```c
/* mrbgems/mruby-rm2/src/display.c
 *
 * Client side of the rm2fb display-server protocol (PLAN.md §3, verified
 * against rM2-stuff libs/rm2fb/include/rm2fb/Message.h). Wire format:
 * int32 variant tag + raw little-endian struct, strict request/reply.
 */
#include <mruby.h>
#include <mruby/class.h>
#include <mruby/data.h>
#include <mruby/error.h>

#include <errno.h>
#include <stdint.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>

enum { TAG_INIT = 0, TAG_UPDATE = 2 };

typedef struct {
  int32_t width;
  int32_t height;
  int32_t pixel_format; /* 0 = RGB565, 1 = RGB32 */
} fb_format;

typedef struct {
  uint8_t own_swtcon;
  uint8_t pad[3];
  fb_format format;
} init_msg; /* 16 bytes on both target ABIs */

typedef struct {
  int sock;
  uint16_t* fb;    /* RGB565 plane; NULL once closed */
  size_t map_size; /* full mapping incl. the trailing gray plane */
  int32_t width;
  int32_t height;
} rm2_display;

static void
rm2_display_dfree(mrb_state* mrb, void* p) {
  rm2_display* d = (rm2_display*)p;
  if (d == NULL) return;
  if (d->fb != NULL) munmap(d->fb, d->map_size);
  if (d->sock >= 0) close(d->sock);
  mrb_free(mrb, d);
}

static const struct mrb_data_type rm2_display_type = {
  "RM2::Display", rm2_display_dfree
};

/* MSG_NOSIGNAL: a dead server must surface as EPIPE, not kill the VM. */
static int
write_exact(int fd, const void* buf, size_t len) {
  const char* p = (const char*)buf;
  while (len > 0) {
    ssize_t n = send(fd, p, len, MSG_NOSIGNAL);
    if (n < 0) {
      if (errno == EINTR) continue;
      return -1;
    }
    p += n;
    len -= (size_t)n;
  }
  return 0;
}

static int
read_exact(int fd, void* buf, size_t len) {
  char* p = (char*)buf;
  while (len > 0) {
    ssize_t n = read(fd, p, len);
    if (n < 0) {
      if (errno == EINTR) continue;
      return -1;
    }
    if (n == 0) {
      errno = ECONNRESET;
      return -1;
    }
    p += n;
    len -= (size_t)n;
  }
  return 0;
}

static int
recv_fd(int sock) {
  char dummy;
  struct iovec iov;
  union {
    struct cmsghdr align;
    char buf[CMSG_SPACE(sizeof(int))];
  } u;
  struct msghdr msg;
  struct cmsghdr* c;
  ssize_t n;
  int fd;

  iov.iov_base = &dummy;
  iov.iov_len = 1;
  memset(&msg, 0, sizeof(msg));
  msg.msg_iov = &iov;
  msg.msg_iovlen = 1;
  msg.msg_control = u.buf;
  msg.msg_controllen = sizeof(u.buf);

  do {
    n = recvmsg(sock, &msg, 0);
  } while (n < 0 && errno == EINTR);
  if (n <= 0) return -1;

  c = CMSG_FIRSTHDR(&msg);
  if (c == NULL || c->cmsg_level != SOL_SOCKET || c->cmsg_type != SCM_RIGHTS)
    return -1;
  memcpy(&fd, CMSG_DATA(c), sizeof(fd));
  return fd;
}

/* Raise a SystemCallError without letting close() clobber errno. */
static void
fail_close(mrb_state* mrb, int fd1, int fd2, const char* msg) {
  int e = errno;
  if (fd1 >= 0) close(fd1);
  if (fd2 >= 0) close(fd2);
  errno = e;
  mrb_sys_fail(mrb, msg);
}

static rm2_display*
get_open_display(mrb_state* mrb, mrb_value self) {
  rm2_display* d = DATA_GET_PTR(mrb, self, &rm2_display_type, rm2_display);
  if (d == NULL || d->fb == NULL)
    mrb_raise(mrb, E_RUNTIME_ERROR, "display is closed");
  return d;
}

static mrb_value
rm2_display_open(mrb_state* mrb, mrb_value klass) {
  const char* path = "/var/run/rm2fb.sock";
  struct sockaddr_un addr;
  int sock, fb_fd;
  int32_t tag = TAG_INIT;
  init_msg init;
  fb_format granted;
  size_t total;
  void* mem;
  rm2_display* d;

  mrb_get_args(mrb, "|z", &path);

  sock = socket(AF_UNIX, SOCK_STREAM, 0);
  if (sock < 0) mrb_sys_fail(mrb, "socket");

  memset(&addr, 0, sizeof(addr));
  addr.sun_family = AF_UNIX;
  if (strlen(path) >= sizeof(addr.sun_path)) {
    close(sock);
    mrb_raise(mrb, E_ARGUMENT_ERROR, "socket path too long");
  }
  strcpy(addr.sun_path, path);
  if (connect(sock, (struct sockaddr*)&addr, sizeof(addr)) < 0)
    fail_close(mrb, sock, -1, "connect to rm2fb socket");

  memset(&init, 0, sizeof(init));
  init.own_swtcon = 0;
  init.format.width = 1404;
  init.format.height = 1872;
  init.format.pixel_format = 0; /* RGB565 */
  if (write_exact(sock, &tag, sizeof(tag)) < 0 ||
      write_exact(sock, &init, sizeof(init)) < 0)
    fail_close(mrb, sock, -1, "send Init");

  if (read_exact(sock, &granted, sizeof(granted)) < 0)
    fail_close(mrb, sock, -1, "read Init reply");
  fb_fd = recv_fd(sock);
  if (fb_fd < 0) {
    close(sock);
    mrb_raise(mrb, E_RUNTIME_ERROR, "server sent no framebuffer fd");
  }
  if (granted.pixel_format != 0 || granted.width <= 0 || granted.height <= 0) {
    close(fb_fd);
    close(sock);
    mrb_raise(mrb, E_RUNTIME_ERROR, "server granted an unsupported buffer format");
  }

  /* RGB565 plane + 1-byte gray plane (PLAN.md §3). */
  total = (size_t)granted.width * granted.height * 3;
  mem = mmap(NULL, total, PROT_READ | PROT_WRITE, MAP_SHARED, fb_fd, 0);
  close(fb_fd); /* the mapping keeps the buffer alive */
  if (mem == MAP_FAILED)
    fail_close(mrb, sock, -1, "mmap framebuffer");

  d = (rm2_display*)mrb_malloc(mrb, sizeof(rm2_display));
  d->sock = sock;
  d->fb = (uint16_t*)mem;
  d->map_size = total;
  d->width = granted.width;
  d->height = granted.height;

  return mrb_obj_value(
    mrb_data_object_alloc(mrb, mrb_class_ptr(klass), d, &rm2_display_type));
}

static mrb_value
rm2_display_width(mrb_state* mrb, mrb_value self) {
  return mrb_int_value(mrb, get_open_display(mrb, self)->width);
}

static mrb_value
rm2_display_height(mrb_state* mrb, mrb_value self) {
  return mrb_int_value(mrb, get_open_display(mrb, self)->height);
}

static mrb_value
rm2_display_close(mrb_state* mrb, mrb_value self) {
  rm2_display* d = DATA_GET_PTR(mrb, self, &rm2_display_type, rm2_display);
  if (d != NULL) {
    if (d->fb != NULL) {
      munmap(d->fb, d->map_size);
      d->fb = NULL;
    }
    if (d->sock >= 0) {
      close(d->sock);
      d->sock = -1;
    }
  }
  return mrb_nil_value();
}

static mrb_value
rm2_display_closed_p(mrb_state* mrb, mrb_value self) {
  rm2_display* d = DATA_GET_PTR(mrb, self, &rm2_display_type, rm2_display);
  return mrb_bool_value(d == NULL || d->fb == NULL);
}

void
rm2_display_init(mrb_state* mrb, struct RClass* rm2) {
  struct RClass* cls =
    mrb_define_class_under(mrb, rm2, "Display", mrb->object_class);
  MRB_SET_INSTANCE_TT(cls, MRB_TT_CDATA);
  mrb_define_class_method(mrb, cls, "open", rm2_display_open, MRB_ARGS_OPT(1));
  mrb_define_method(mrb, cls, "width", rm2_display_width, MRB_ARGS_NONE());
  mrb_define_method(mrb, cls, "height", rm2_display_height, MRB_ARGS_NONE());
  mrb_define_method(mrb, cls, "close", rm2_display_close, MRB_ARGS_NONE());
  mrb_define_method(mrb, cls, "closed?", rm2_display_closed_p, MRB_ARGS_NONE());
}
```

And replace `mrbgems/mruby-rm2/src/gem.c` with:

```c
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
```

- [ ] **Step 6: Run tests to verify they pass**

Run: `make test`
Expected: `KO: 0`, `Crash: 0`. This also proves the cross target compiles
the new gem sources (`src/display.c`, `src/gem.c` enter its `libmruby.a`).
The test scaffolding (`test/fake_server.c`) compiles for the host target
only — the cross target's `build_mrbtest_lib_only` skips test-file
generation, which is fine: the fake server exists to run host-side.

- [ ] **Step 7: Commit**

```bash
git add mrbgems/mruby-rm2
git commit -m "feat: RM2::Display.open — Init handshake, SCM_RIGHTS fd, mmap"
```

---

### Task 5: fill_rect and pixel

Pixel pushing in C with clamping, verified by reading pixels back out of the
shared mapping.

**Files:**
- Modify: `mrbgems/mruby-rm2/src/display.c`
- Modify: `mrbgems/mruby-rm2/test/display.rb` (append)

**Interfaces:**
- Consumes: `rm2_display` struct, `get_open_display`, `RM2::TestServer` from Task 4.
- Produces: `Display#fill_rect(x, y, w, h, gray) → self` (gray 0–255, rect clamped to the framebuffer, out-of-range gray raises `ArgumentError`); `Display#pixel(x, y) → Integer` (RGB565 value; out-of-bounds raises `RangeError`). Task 6+ and the game renderer rely on these exact signatures.

**Carried hardening from Task 4's review** (apply during Step 3, same
commit — behavior-preserving for all tested paths, so no new tests; the
fake server always sends a correctly-sized fd):

In `rm2_display_open`, replace the reply-handling sequence (from the
`read_exact(sock, &granted, …)` call through the `mmap` call) with the
following, which (a) validates the granted format *before* the blocking
`recv_fd` so a bad grant raises instead of hanging, and (b) `fstat`s the
received fd before mapping — mmap never validates length, and a server
granting more than the fd holds would otherwise hand `fill_rect`/`pixel`
a SIGBUS:

```c
  if (read_exact(sock, &granted, sizeof(granted)) < 0)
    fail_close(mrb, sock, -1, "read Init reply");
  if (granted.pixel_format != 0 || granted.width <= 0 || granted.height <= 0) {
    close(sock);
    mrb_raise(mrb, E_RUNTIME_ERROR, "server granted an unsupported buffer format");
  }
  fb_fd = recv_fd(sock);
  if (fb_fd < 0) {
    close(sock);
    mrb_raise(mrb, E_RUNTIME_ERROR, "server sent no framebuffer fd");
  }

  /* RGB565 plane + 1-byte gray plane (PLAN.md §3). */
  total = (size_t)granted.width * granted.height * 3;
  if (fstat(fb_fd, &st) < 0)
    fail_close(mrb, fb_fd, sock, "fstat framebuffer fd");
  if ((size_t)st.st_size < total) {
    close(fb_fd);
    close(sock);
    mrb_raise(mrb, E_RUNTIME_ERROR, "framebuffer fd smaller than granted format");
  }

  mem = mmap(NULL, total, PROT_READ | PROT_WRITE, MAP_SHARED, fb_fd, 0);
```

This needs `#include <sys/stat.h>` with the other system includes and a
`struct stat st;` declaration alongside the other locals in
`rm2_display_open`.

- [ ] **Step 1: Write the failing tests (append to test/display.rb)**

```ruby
assert('fill_rect writes RGB565 pixels into the shared buffer') do
  path = RM2::TestServer.start
  begin
    d = RM2::Display.open(path)
    assert_equal 0x0000, d.pixel(10, 20) # memfd starts zeroed (black)
    d.fill_rect(10, 20, 3, 2, 255)
    assert_equal 0xFFFF, d.pixel(10, 20) # top-left corner
    assert_equal 0xFFFF, d.pixel(12, 21) # bottom-right corner
    assert_equal 0x0000, d.pixel(13, 20) # right edge is exclusive
    assert_equal 0x0000, d.pixel(10, 22) # bottom edge is exclusive
    d.fill_rect(0, 0, 1, 1, 128)
    assert_equal 0x8410, d.pixel(0, 0)   # (128>>3)|((128>>2)<<5)|((128>>3)<<11)
  ensure
    RM2::TestServer.stop
  end
end

assert('fill_rect clamps to the framebuffer bounds') do
  path = RM2::TestServer.start
  begin
    d = RM2::Display.open(path)
    d.fill_rect(1400, 1868, 100, 100, 255) # spills past both edges
    assert_equal 0xFFFF, d.pixel(1403, 1871)
    d.fill_rect(-5, -5, 10, 10, 255)       # spills past the origin
    assert_equal 0xFFFF, d.pixel(0, 0)
    assert_equal 0xFFFF, d.pixel(4, 4)
    assert_equal 0x0000, d.pixel(5, 5)
  ensure
    RM2::TestServer.stop
  end
end

assert('fill_rect and pixel validate their arguments') do
  path = RM2::TestServer.start
  begin
    d = RM2::Display.open(path)
    assert_raise(ArgumentError) { d.fill_rect(0, 0, 1, 1, 256) }
    assert_raise(ArgumentError) { d.fill_rect(0, 0, 1, 1, -1) }
    assert_raise(RangeError) { d.pixel(1404, 0) }
    assert_raise(RangeError) { d.pixel(0, -1) }
  ensure
    RM2::TestServer.stop
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `make test`
Expected: the three new assertions fail with NoMethodError (`fill_rect` /
`pixel` undefined); everything else passes.

- [ ] **Step 3: Implement fill_rect and pixel**

Add to `mrbgems/mruby-rm2/src/display.c` (above `rm2_display_init`):

```c
static mrb_value
rm2_display_fill_rect(mrb_state* mrb, mrb_value self) {
  mrb_int x, y, w, h, gray;
  rm2_display* d;
  mrb_int x2, y2, row, col;
  uint16_t px;

  mrb_get_args(mrb, "iiiii", &x, &y, &w, &h, &gray);
  d = get_open_display(mrb, self);

  if (gray < 0 || gray > 255)
    mrb_raise(mrb, E_ARGUMENT_ERROR, "gray must be 0..255");

  x2 = x + w; /* exclusive */
  y2 = y + h;
  if (x < 0) x = 0;
  if (y < 0) y = 0;
  if (x2 > d->width) x2 = d->width;
  if (y2 > d->height) y2 = d->height;
  if (x >= x2 || y >= y2) return self;

  px = (uint16_t)((gray >> 3) | ((gray >> 2) << 5) | ((gray >> 3) << 11));
  for (row = y; row < y2; row++) {
    uint16_t* p = d->fb + (size_t)row * d->width + x;
    for (col = x; col < x2; col++) *p++ = px;
  }
  return self;
}

static mrb_value
rm2_display_pixel(mrb_state* mrb, mrb_value self) {
  mrb_int x, y;
  rm2_display* d;

  mrb_get_args(mrb, "ii", &x, &y);
  d = get_open_display(mrb, self);
  if (x < 0 || x >= d->width || y < 0 || y >= d->height)
    mrb_raise(mrb, E_RANGE_ERROR, "pixel out of bounds");
  return mrb_int_value(mrb, d->fb[(size_t)y * d->width + x]);
}
```

And register them inside `rm2_display_init` (after the `closed?` line):

```c
  mrb_define_method(mrb, cls, "fill_rect", rm2_display_fill_rect, MRB_ARGS_REQ(5));
  mrb_define_method(mrb, cls, "pixel", rm2_display_pixel, MRB_ARGS_REQ(2));
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `make test`
Expected: `KO: 0`, `Crash: 0`.

- [ ] **Step 5: Commit**

```bash
git add mrbgems/mruby-rm2
git commit -m "feat: Display#fill_rect and #pixel with clamping"
```

---

### Task 6: update — damage rectangles on the wire

Sends `UpdateParams` and reads the ack; the fake server's log lets the test
assert the exact 32 wire bytes, including the y-first inclusive-corner
conversion the real server requires.

**Files:**
- Modify: `mrbgems/mruby-rm2/src/display.c`
- Modify: `mrbgems/mruby-rm2/mrblib/rm2.rb` (append the kwargs wrapper)
- Modify: `mrbgems/mruby-rm2/test/display.rb` (append)

**Interfaces:**
- Consumes: everything from Tasks 4–5; `RM2::GL16`/`GC16`/`SYNC` constants from Task 3; `RM2::TestServer.log_path`.
- Produces: `Display#update(x, y, w, h, waveform: RM2::GL16, flags: 0) → bool` (the ack; rect clamped, empty-after-clamp returns true without sending) and the C primitive `Display#update_raw(x, y, w, h, waveform, flags) → bool`. The game's renderer calls `#update` with these exact keywords.

- [ ] **Step 1: Write the failing tests (append to test/display.rb)**

```ruby
assert('update sends y-first inclusive corners and reads the ack') do
  path = RM2::TestServer.start
  begin
    d = RM2::Display.open(path)
    assert_true d.update(100, 200, 50, 25, waveform: RM2::GC16, flags: RM2::SYNC)
    log = File.open(RM2::TestServer.log_path) { |f| f.read }
    assert_equal 32, log.bytesize
    y1, x1, y2, x2, flags, waveform, temp_bits, extra = log.unpack('V8')
    assert_equal 200, y1
    assert_equal 100, x1
    assert_equal 224, y2          # 200 + 25 - 1: inclusive corner
    assert_equal 149, x2          # 100 + 50 - 1
    assert_equal RM2::SYNC, flags
    assert_equal 0xf002, waveform # GC16 | WAVEFORM_FLAG
    assert_equal 0, temp_bits     # 0.0f is all-zero bits
    assert_equal 0, extra
  ensure
    RM2::TestServer.stop
  end
end

assert('update defaults to GL16 with no flags and clamps the rect') do
  path = RM2::TestServer.start
  begin
    d = RM2::Display.open(path)
    assert_true d.update(1400, 0, 100, 10)
    _y1, x1, _y2, x2, flags, waveform, _temp, _extra =
      File.open(RM2::TestServer.log_path) { |f| f.read }.unpack('V8')
    assert_equal 1400, x1
    assert_equal 1403, x2         # clamped to the panel edge, inclusive
    assert_equal 0, flags
    assert_equal 0xf003, waveform # GL16 | WAVEFORM_FLAG
  ensure
    RM2::TestServer.stop
  end
end

assert('update on an empty rect is a no-op') do
  path = RM2::TestServer.start
  begin
    d = RM2::Display.open(path)
    assert_true d.update(2000, 2000, 50, 50) # fully off-screen
    assert_true d.update(0, 0, 0, 10)        # zero width
    log = File.open(RM2::TestServer.log_path) { |f| f.read }
    assert_equal 0, log.bytesize             # nothing hit the wire
  ensure
    RM2::TestServer.stop
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `make test`
Expected: the three new assertions fail with NoMethodError (`update`
undefined); everything else passes.

- [ ] **Step 3: Implement update_raw in C**

Add to `mrbgems/mruby-rm2/src/display.c` (above `rm2_display_init`). The
struct goes with the other typedefs near the top of the file:

```c
typedef struct {
  int32_t y1, x1, y2, x2; /* inclusive corners, y first */
  int32_t flags;
  int32_t waveform;
  float temperature;
  int32_t extra_mode;
} update_params; /* 32 bytes on both target ABIs */
```

```c
static mrb_value
rm2_display_update_raw(mrb_state* mrb, mrb_value self) {
  mrb_int x, y, w, h, waveform, flags;
  rm2_display* d;
  mrb_int x2, y2;
  int32_t tag = TAG_UPDATE;
  update_params up;
  uint8_t ack;

  mrb_get_args(mrb, "iiiiii", &x, &y, &w, &h, &waveform, &flags);
  d = get_open_display(mrb, self);

  x2 = x + w; /* exclusive */
  y2 = y + h;
  if (x < 0) x = 0;
  if (y < 0) y = 0;
  if (x2 > d->width) x2 = d->width;
  if (y2 > d->height) y2 = d->height;
  if (x >= x2 || y >= y2) return mrb_true_value(); /* nothing to flush */

  up.y1 = (int32_t)y;
  up.x1 = (int32_t)x;
  up.y2 = (int32_t)(y2 - 1); /* inclusive corners */
  up.x2 = (int32_t)(x2 - 1);
  up.flags = (int32_t)flags;
  up.waveform = (int32_t)waveform;
  up.temperature = 0.0f;
  up.extra_mode = 0;

  if (write_exact(d->sock, &tag, sizeof(tag)) < 0 ||
      write_exact(d->sock, &up, sizeof(up)) < 0)
    mrb_sys_fail(mrb, "send update");
  if (read_exact(d->sock, &ack, sizeof(ack)) < 0)
    mrb_sys_fail(mrb, "read update ack");
  return mrb_bool_value(ack != 0);
}
```

Register inside `rm2_display_init`:

```c
  mrb_define_method(mrb, cls, "update_raw", rm2_display_update_raw, MRB_ARGS_REQ(6));
```

- [ ] **Step 4: Add the kwargs wrapper in mrblib**

Append inside `module RM2` in `mrbgems/mruby-rm2/mrblib/rm2.rb`:

```ruby
  class Display
    # Flush a damage rectangle to the panel. Returns the server's ack
    # (false means we are not the front client and the update was dropped).
    def update(x, y, w, h, waveform: GL16, flags: 0)
      update_raw(x, y, w, h, waveform, flags)
    end
  end
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `make test`
Expected: `KO: 0`, `Crash: 0`.

- [ ] **Step 6: Commit**

```bash
git add mrbgems/mruby-rm2
git commit -m "feat: Display#update — UpdateParams packing with inclusive corners"
```

---

### Task 7: checkerboard demo, gem README, full verification

The Milestone-0 payload: the cross-built stock `bin/mruby` plus this script
is everything the on-device smoke test needs.

**Files:**
- Create: `examples/checkerboard.rb`
- Create: `mrbgems/mruby-rm2/README.md`

**Interfaces:**
- Consumes: the full `RM2::Display` API (`open`, `width`, `height`, `fill_rect`, `update`, `close`).
- Produces: `examples/checkerboard.rb`, runnable on the device as `./mruby checkerboard.rb` once the rm2fb server is installed (Milestone 0 — out of scope here).

- [ ] **Step 1: Write the demo script**

```ruby
# examples/checkerboard.rb — Milestone 0 smoke test payload.
# On the device (rm2fb server running):
#   ./mruby checkerboard.rb [/var/run/rm2fb.sock]
d = RM2::Display.open(*ARGV)
cell = 156 # 1404 / 9
cols = (d.width + cell - 1) / cell
rows = (d.height + cell - 1) / cell
rows.times do |r|
  cols.times do |c|
    d.fill_rect(c * cell, r * cell, cell, cell, (r + c).odd? ? 0 : 255)
  end
end
d.update(0, 0, d.width, d.height, waveform: RM2::GC16, flags: RM2::SYNC)
d.close
puts "checkerboard flushed: #{cols}x#{rows} cells"
```

- [ ] **Step 2: Syntax-check the demo with the built mrbc**

Run:
```bash
docker run --rm --platform linux/amd64 -v "$PWD":/work redoku-build \
  /work/build/host/bin/mrbc -c /work/examples/checkerboard.rb
```
Expected: exits 0, no output. (If it reports a syntax error, fix the script —
this catches typos without a device.)

- [ ] **Step 3: Write the gem README**

````markdown
# mruby-rm2

mruby client for the [rM2-stuff](https://github.com/timower/rM2-stuff)
`rm2fb` display server on the reMarkable 2.

```ruby
d = RM2::Display.open               # or .open("/path/to/rm2fb.sock")
d.fill_rect(0, 0, d.width, d.height, 255)      # white; gray is 0..255
d.fill_rect(100, 100, 200, 200, 0)             # black square
d.update(0, 0, d.width, d.height,
         waveform: RM2::GC16, flags: RM2::SYNC) # flush to the panel
d.pixel(100, 100)  # => 0x0000 (RGB565 readback)
d.close
```

Waveforms: `RM2::DU` (fast pen ink), `RM2::GL16` (UI), `RM2::GC16` (full,
flashing refresh), `RM2::A2`. Flags: `RM2::SYNC`, `RM2::FAST_DRAW`.
`#update` returns the server's ack — `false` means another client is front
and the update was dropped.

Tests run against a fake protocol server (`test/fake_server.c`, forked by
mrbtest via the `mrb_mruby_rm2_gem_test` hook) — see `test/display.rb`.
Protocol reference: `PLAN.md` §3 in the repo root.
````

- [ ] **Step 4: Full verification**

Run: `make test && make build && file build/rm2/bin/mruby`
Expected: `KO: 0` / `Crash: 0`; the `file` output contains `ARM, EABI5`.

- [ ] **Step 5: Commit**

```bash
git add examples/checkerboard.rb mrbgems/mruby-rm2/README.md
git commit -m "feat: checkerboard demo script and mruby-rm2 README"
```

---

## Out of scope (explicitly)

- On-device execution (Milestone 0 needs the rm2fb server installed first — separate task).
- `RM2::Input`, `RM2::Control`, `RM2::Inotify`, `RM2.setup_signals`, `draw_line`, `blit` (PLAN.md §5 — later plans).
- Reconnect-on-EPIPE handling (game-level policy, PLAN.md §11).
- `UpdateBatchHeader` (tag 3) and ack-false simulation in the fake server.
