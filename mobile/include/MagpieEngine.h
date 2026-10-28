#ifndef MAGPIE_ENGINE_H
#define MAGPIE_ENGINE_H
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
/* Completion bytes are borrowed only until the callback returns. Copy before scheduling work. */
typedef void (*MagpieCompletion)(uint64_t request_id, const uint8_t *bytes, size_t count, void *context);
uint64_t magpie_engine_create(const uint8_t *config, size_t count);
bool magpie_engine_request(uint64_t handle, uint64_t request_id, const uint8_t *bytes, size_t count, MagpieCompletion completion, void *context);
bool magpie_engine_set_active(uint64_t handle, bool active);
void magpie_engine_cancel(uint64_t handle, uint64_t request_id);
bool magpie_engine_destroy(uint64_t handle, MagpieCompletion completion, void *context);
#endif
