/* Test-only real ext-data-control reader. Request into the caller's pipe, then
 * exit without draining it. Python controls pipe capacity, progress and closure. */
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <wayland-client.h>
#include "control.h"

static struct wl_seat *seat;
static struct ext_data_control_manager_v1 *manager;
static struct ext_data_control_offer_v1 *selection;
static void global(void *data, struct wl_registry *registry, uint32_t name,
                   const char *interface, uint32_t version) {
    (void)data; (void)version;
    if (!strcmp(interface, "wl_seat") && !seat)
        seat = wl_registry_bind(registry, name, &wl_seat_interface, 1);
    if (!strcmp(interface, "ext_data_control_manager_v1"))
        manager = wl_registry_bind(registry, name, &ext_data_control_manager_v1_interface, 1);
}
static void removed(void *data, struct wl_registry *registry, uint32_t name) {
    (void)data; (void)registry; (void)name;
}
static void mime(void *data, struct ext_data_control_offer_v1 *offer, const char *type) {
    (void)data; (void)offer; (void)type;
}
static const struct ext_data_control_offer_v1_listener offer_listener = { mime };
static void offered(void *data, struct ext_data_control_device_v1 *device,
                    struct ext_data_control_offer_v1 *offer) {
    (void)data; (void)device;
    ext_data_control_offer_v1_add_listener(offer, &offer_listener, NULL);
}
static void selected(void *data, struct ext_data_control_device_v1 *device,
                     struct ext_data_control_offer_v1 *offer) {
    (void)data; (void)device;
    selection = offer;
}
static void primary(void *data, struct ext_data_control_device_v1 *device,
                    struct ext_data_control_offer_v1 *offer) {
    (void)data; (void)device; (void)offer;
}
static void finished(void *data, struct ext_data_control_device_v1 *device) {
    (void)data; (void)device;
    _exit(2);
}
static const struct wl_registry_listener registry_listener = { global, removed };
static const struct ext_data_control_device_v1_listener device_listener = {
    offered, selected, finished, primary
};
int main(int argc, char **argv) {
    if (argc != 3) return 2;
    struct wl_display *display = wl_display_connect(NULL);
    if (!display) return 2;
    struct wl_registry *registry = wl_display_get_registry(display);
    wl_registry_add_listener(registry, &registry_listener, NULL);
    if (wl_display_roundtrip(display) < 0 || !seat || !manager) return 2;
    struct ext_data_control_device_v1 *device =
        ext_data_control_manager_v1_get_data_device(manager, seat);
    ext_data_control_device_v1_add_listener(device, &device_listener, NULL);
    if (wl_display_roundtrip(display) < 0 || !selection) return 2;
    int fd = atoi(argv[1]);
    ext_data_control_offer_v1_receive(selection, argv[2], fd);
    close(fd);
    if (wl_display_roundtrip(display) < 0) return 2;
    /* Disconnecting the requesting client does not close the transferred fd. */
    wl_display_disconnect(display);
    return 0;
}
