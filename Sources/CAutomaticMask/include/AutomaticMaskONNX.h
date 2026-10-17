#ifndef LUMA_AUTOMATIC_MASK_ONNX_H
#define LUMA_AUTOMATIC_MASK_ONNX_H
#include <stdint.h>
#include <stddef.h>
#ifdef __cplusplus
extern "C" {
#endif
/* Portable ONNX Runtime adapter. The application supplies a runtime library and
   model path; no Apple framework, pixel layout, or platform GPU type crosses ABI. */
void *luma_onnx_create(const char *runtime_path, const char *model_path, char *error, size_t error_size);
void luma_onnx_destroy(void *session);
/* Model contract is Float32; the caller specifies NCHW or NHWC layout. Shape reports model static dimensions, or -1. */
int luma_onnx_input_shape(void *session, int64_t shape[4], char *error, size_t error_size);
/* Caller owns output, releases it with luma_onnx_free. First model output only.
   Float16 output is converted to Float32, preserving a portable host contract. */
int luma_onnx_run(void *session, const float *input, const int64_t shape[4], float **output,
                  int64_t output_shape[4], size_t *output_count, char *error, size_t error_size);
/* Two-input image/mask variant for portable inpainting. Each tensor has its own
   NCHW dimensions; output ownership and Float32 contract match luma_onnx_run. */
int luma_onnx_run_masked(void *session, const float *input, const int64_t shape[4],
                         const float *mask, const int64_t mask_shape[4], float **output,
                         int64_t output_shape[4], size_t *output_count, char *error, size_t error_size);
void luma_onnx_free(void *data);
#ifdef __cplusplus
}
#endif
#endif
