#ifndef LUMA_RAW_H
#define LUMA_RAW_H
#include <stddef.h>
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
typedef struct {
 uint16_t *rgb; int width,height; size_t count;
 float iso,shutter,aperture,focal;
 char make[64],model[64];
} LumaRawImage;
int luma_raw_decode(const void *data,size_t length,LumaRawImage *out,char *error,size_t error_size);
void luma_raw_free(LumaRawImage *image);
const char *luma_raw_version(void);
#ifdef __cplusplus
}
#endif
#endif
