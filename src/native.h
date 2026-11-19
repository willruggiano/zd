#pragma once
#include <pipewire/pipewire.h>
#include <pipewire/extensions/metadata.h>
#include <spa/param/audio/format-utils.h>
#include <whisper.h>
#include <pthread.h>

// C-only inline/macro APIs. No application allocation or retained state here.
struct pw_registry *zd_registry(struct pw_core *core);
int zd_registry_listen(struct pw_registry *, struct spa_hook *, const struct pw_registry_events *, void *);
struct pw_metadata *zd_metadata(struct pw_registry *, uint32_t);
int zd_metadata_listen(struct pw_metadata *, struct spa_hook *, const struct pw_metadata_events *, void *);
int zd_core_listen(struct pw_core *, struct spa_hook *, const struct pw_core_events *, void *);
const char *zd_property(const struct spa_dict *, const char *);
int zd_default_name(const char *, char *, int);
int zd_iterate(struct pw_loop *);
int zd_loop_fd(struct pw_loop *);
void zd_enter(struct pw_loop *);
void zd_leave(struct pw_loop *);
int zd_connect(struct pw_stream *, void *, size_t);
bool zd_format(const struct spa_pod *);
