#ifndef CLOAK_BRIDGE_H
#define CLOAK_BRIDGE_H

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct Session CloakSession;

#define CLOAK_OK 0
#define CLOAK_ERR_PAIRING 1
#define CLOAK_ERR_CONNECT 2
#define CLOAK_ERR_MOUNT 3
#define CLOAK_ERR_SERVICE 4
#define CLOAK_ERR_STATE 5
#define CLOAK_ERR_BUFFER 6

CloakSession *cloak_session_new(const unsigned char *pairing, size_t length, const char *addresses);
int cloak_session_connect(CloakSession *session);
int cloak_session_device_info(CloakSession *session, char *out, size_t capacity);
int cloak_session_mount(CloakSession *session,
                        const unsigned char *image, size_t image_length,
                        const unsigned char *trust_cache, size_t trust_cache_length,
                        const unsigned char *manifest, size_t manifest_length);
int cloak_session_open_service(CloakSession *session);
int cloak_session_set_location(CloakSession *session, double latitude, double longitude);
int cloak_session_clear_location(CloakSession *session);
const char *cloak_session_last_error(CloakSession *session);
void cloak_session_free(CloakSession *session);
int cloak_probe_rsd(const char *address, unsigned short port, char *out, size_t capacity);
int cloak_rp_start(const char *address, unsigned short port, const char *pairing_base64);
int cloak_rp_state(char *out, size_t capacity);
int cloak_rp_submit_pin(const char *pin);

int cloak_rp_set_location(double latitude, double longitude);
int cloak_rp_clear_location(void);
int cloak_rp_mount(const unsigned char *image, size_t image_len,
                   const unsigned char *trust_cache, size_t trust_cache_len,
                   const unsigned char *manifest, size_t manifest_len,
                   unsigned long long chip_id);
int cloak_rp_stop(void);
int cloak_rp_host_start(const char *name, const char *pairing_base64, const char *alt_irk_base64);


#ifdef __cplusplus
}
#endif

#endif
