#ifndef LUMA_CORE_H
#define LUMA_CORE_H
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
/* Row-major coverage. Coordinates in pixels, origin top-left. Union never builds up. */
void luma_brush_segment(uint8_t *coverage, int width, int height,
                       double x0, double y0, double x1, double y1,
                       double radius_pixels, double feather);
uint32_t luma_core_version(void);
float luma_sigma_mean(const float *values,int count,float sigma);
/* Moving -> reference, row-major homogeneous matrix; top-left pixel coordinates. */
int luma_register_rgba(const uint8_t *reference,int rw,int rh,const uint8_t *moving,int mw,int mh,int projective,double *matrix);
#ifdef __cplusplus
}
#endif
#endif
