#define _GNU_SOURCE 1
// Keep the translated va_list callback ABI for sanitized libwayland logging.
// Protocol objects and requests come from zig-wayland instead.
#include <wayland-client-core.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <poll.h>
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>
#include <signal.h>
#include <time.h>
#include <stdlib.h>

#include <pipewire/pipewire.h>
#include <pipewire/extensions/metadata.h>
#include <spa/param/audio/format-utils.h>
#include <spa/utils/json.h>
#include <whisper.h>
#include <pthread.h>
