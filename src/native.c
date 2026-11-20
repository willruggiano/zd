#include "native.h"
#include <spa/utils/json.h>
#include <string.h>
struct pw_registry *zd_registry(struct pw_core *c) { return pw_core_get_registry(c, PW_VERSION_REGISTRY, 0); }
int zd_registry_listen(struct pw_registry *r, struct spa_hook *h, const struct pw_registry_events *e, void *d) { return pw_registry_add_listener(r, h, e, d); }
struct pw_metadata *zd_metadata(struct pw_registry *r, uint32_t id) { return pw_registry_bind(r, id, PW_TYPE_INTERFACE_Metadata, PW_VERSION_METADATA, 0); }
int zd_metadata_listen(struct pw_metadata *m, struct spa_hook *h, const struct pw_metadata_events *e, void *d) { return pw_metadata_add_listener(m, h, e, d); }
int zd_core_listen(struct pw_core *c, struct spa_hook *h, const struct pw_core_events *e, void *d) { return pw_core_add_listener(c, h, e, d); }
const char *zd_property(const struct spa_dict *d, const char *k) { return d ? spa_dict_lookup(d, k) : NULL; }
int zd_default_name(const char *v, char *out, int size) { return spa_json_str_object_find(v, strlen(v), "name", out, size); }
int zd_iterate(struct pw_loop *l) { return pw_loop_iterate(l, 0); }
int zd_loop_fd(struct pw_loop *l) { return pw_loop_get_fd(l); }
void zd_enter(struct pw_loop *l) { pw_loop_enter(l); }
void zd_leave(struct pw_loop *l) { pw_loop_leave(l); }
int zd_connect(struct pw_stream *s, void *buffer, size_t size) {
    struct spa_pod_builder b = SPA_POD_BUILDER_INIT(buffer, size);
    const struct spa_pod *p = spa_format_audio_raw_build(&b, SPA_PARAM_EnumFormat,
        &SPA_AUDIO_INFO_RAW_INIT(.format = SPA_AUDIO_FORMAT_F32, .rate = 16000,
                                .channels = 1, .position = { SPA_AUDIO_CHANNEL_MONO }));
    if (!p) return -ENOSPC;
    // Not RT_PROCESS: callbacks are serialized on our main/control loop.
    return pw_stream_connect(s, PW_DIRECTION_INPUT, PW_ID_ANY,
        PW_STREAM_FLAG_AUTOCONNECT | PW_STREAM_FLAG_MAP_BUFFERS, &p, 1);
}
bool zd_format(const struct spa_pod *p) {
    struct spa_audio_info_raw info = {0};
    return spa_format_audio_raw_parse(p, &info) >= 0 && info.format == SPA_AUDIO_FORMAT_F32 && info.rate == 16000 && info.channels == 1;
}
