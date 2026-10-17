#include "AutomaticMaskONNX.h"
#include "../../Vendor/ONNXRuntime/include/onnxruntime_c_api.h"
#include <stdlib.h>
#include <stdio.h>
#include <string.h>
#include <math.h>
#ifdef _WIN32
#include <windows.h>
#else
#include <dlfcn.h>
#endif

typedef struct {
    void *library;
    const OrtApi *api;
    OrtEnv *env;
    OrtSession *session;
    OrtAllocator *allocator;
    char *input_name;
    char *output_name;
    char *mask_name;
} LumaONNX;

static void message(char *error, size_t size, const char *text) {
    if (error && size) snprintf(error, size, "%s", text ? text : "ONNX error");
}
static int checked(LumaONNX *s, OrtStatus *status, char *error, size_t size) {
    if (!status) return 1;
    message(error, size, s->api->GetErrorMessage(status));
    s->api->ReleaseStatus(status);
    return 0;
}
static void *open_library(const char *path) {
#ifdef _WIN32
    int length = MultiByteToWideChar(CP_UTF8,0,path,-1,NULL,0);
    wchar_t *wide = calloc((size_t)length,sizeof(wchar_t));
    if (!wide) return NULL;
    MultiByteToWideChar(CP_UTF8,0,path,-1,wide,length);
    void *library = (void *)LoadLibraryW(wide);
    free(wide);
    return library;
#else
    return dlopen(path, RTLD_NOW | RTLD_LOCAL);
#endif
}
static void close_library(void *lib) {
#ifdef _WIN32
    FreeLibrary((HMODULE)lib);
#else
    dlclose(lib);
#endif
}
void luma_onnx_destroy(void *opaque) {
    LumaONNX *s = (LumaONNX *)opaque;
    if (!s) return;
    if (s->api) {
        if (s->input_name) s->allocator->Free(s->allocator, s->input_name);
        if (s->output_name) s->allocator->Free(s->allocator, s->output_name);
        if (s->mask_name) s->allocator->Free(s->allocator, s->mask_name);
        if (s->session) s->api->ReleaseSession(s->session);
        if (s->env) s->api->ReleaseEnv(s->env);
    }
    if (s->library) close_library(s->library);
    free(s);
}
void *luma_onnx_create(const char *runtime_path, const char *model_path, char *error, size_t size) {
    if (!runtime_path || !model_path) { message(error,size,"Missing runtime or model path"); return NULL; }
    LumaONNX *s = calloc(1,sizeof(LumaONNX));
    if (!s) return NULL;
    s->library = open_library(runtime_path);
    if (!s->library) { message(error,size,"Cannot load bundled ONNX Runtime"); luma_onnx_destroy(s); return NULL; }
#ifdef _WIN32
    const OrtApiBase *(*get_api)(void) = (void *)GetProcAddress((HMODULE)s->library,"OrtGetApiBase");
#else
    const OrtApiBase *(*get_api)(void) = (void *)dlsym(s->library,"OrtGetApiBase");
#endif
    if (!get_api || !(s->api = get_api()->GetApi(ORT_API_VERSION))) {
        message(error,size,"Incompatible ONNX Runtime C API"); luma_onnx_destroy(s); return NULL;
    }
    OrtSessionOptions *options = NULL;
    if (!checked(s,s->api->CreateEnv(ORT_LOGGING_LEVEL_WARNING,"LumaLab masks",&s->env),error,size)) goto fail;
    if (!checked(s,s->api->CreateSessionOptions(&options),error,size)) goto fail;
    if (!checked(s,s->api->SetIntraOpNumThreads(options,4),error,size)) goto fail;
    if (!checked(s,s->api->SetSessionGraphOptimizationLevel(options,ORT_ENABLE_ALL),error,size)) goto fail;
#ifdef _WIN32
    int length = MultiByteToWideChar(CP_UTF8,0,model_path,-1,NULL,0);
    wchar_t *wide = calloc((size_t)length,sizeof(wchar_t));
    if (!wide) { message(error,size,"Cannot allocate model path"); goto fail; }
    MultiByteToWideChar(CP_UTF8,0,model_path,-1,wide,length);
    int success = checked(s,s->api->CreateSession(s->env,wide,options,&s->session),error,size);
    free(wide);
    if (!success) goto fail;
#else
    if (!checked(s,s->api->CreateSession(s->env,model_path,options,&s->session),error,size)) goto fail;
#endif
    s->api->ReleaseSessionOptions(options); options = NULL;
    if (!checked(s,s->api->GetAllocatorWithDefaultOptions(&s->allocator),error,size)) goto fail;
    if (!checked(s,s->api->SessionGetInputName(s->session,0,s->allocator,&s->input_name),error,size)) goto fail;
    if (!checked(s,s->api->SessionGetOutputName(s->session,0,s->allocator,&s->output_name),error,size)) goto fail;
    size_t input_count = 0;
    if (!checked(s,s->api->SessionGetInputCount(s->session,&input_count),error,size)) goto fail;
    if (input_count == 2 && !checked(s,s->api->SessionGetInputName(s->session,1,s->allocator,&s->mask_name),error,size)) goto fail;
    if (input_count > 2) { message(error,size,"Models with more than two inputs are not supported"); goto fail; }
    return s;
fail:
    if (options) s->api->ReleaseSessionOptions(options);
    luma_onnx_destroy(s);
    return NULL;
}
int luma_onnx_input_shape(void *opaque, int64_t shape[4], char *error, size_t size) {
    LumaONNX *s = opaque; if (!s || !shape) return 0;
    OrtTypeInfo *type = NULL; const OrtTensorTypeAndShapeInfo *tensor = NULL;
    if (!checked(s,s->api->SessionGetInputTypeInfo(s->session,0,&type),error,size)) return 0;
    int ok = checked(s,s->api->CastTypeInfoToTensorInfo(type,&tensor),error,size);
    size_t dimensions = 0;
    if (ok) ok = checked(s,s->api->GetDimensionsCount(tensor,&dimensions),error,size);
    if (ok && dimensions != 4) { message(error,size,"Model input must have four dimensions"); ok = 0; }
    if (ok) ok = checked(s,s->api->GetDimensions(tensor,shape,4),error,size);
    ONNXTensorElementDataType element = ONNX_TENSOR_ELEMENT_DATA_TYPE_UNDEFINED;
    if (ok) ok = checked(s,s->api->GetTensorElementType(tensor,&element),error,size);
    if (ok && element != ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT) { message(error,size,"Model input must be Float32"); ok = 0; }
    s->api->ReleaseTypeInfo(type);
    return ok;
}
static float half_float(uint16_t h) {
    unsigned sign = h >> 15, exp = (h >> 10)&31, frac = h&1023;
    float value = exp == 0 ? ldexpf((float)frac,-24) : exp == 31 ? (frac ? NAN : INFINITY) : ldexpf(1.0f+(float)frac/1024.0f,(int)exp-15);
    return sign ? -value : value;
}
static int run_internal(void *opaque, const float *input, const int64_t shape[4], const float *mask, const int64_t mask_shape[4], float **output,
                  int64_t outshape[4], size_t *output_count, char *error, size_t size) {
    LumaONNX *s = opaque;
    if (!s || !input || !shape || !output || !outshape || !output_count) return 0;
    *output = NULL; *output_count = 0;
    size_t count = 1;
    for (int i=0;i<4;i++) {
        if (shape[i] <= 0 || shape[i] > 8192 || (size_t)shape[i] > 67108864/count) { message(error,size,"Invalid input dimensions"); return 0; }
        count *= (size_t)shape[i];
    }
    if (mask && (!mask_shape || !s->mask_name)) { message(error,size,"Model has no mask input"); return 0; }
    if (!mask && s->mask_name) { message(error,size,"Model requires a mask input"); return 0; }
    size_t mask_count = 1;
    if (mask) {
        for (int i=0;i<4;i++) {
            if (mask_shape[i] <= 0 || mask_shape[i] > 8192 || (size_t)mask_shape[i] > 67108864/mask_count) { message(error,size,"Invalid mask dimensions"); return 0; }
            mask_count *= (size_t)mask_shape[i];
        }
    }
    OrtMemoryInfo *memory = NULL; OrtValue *in = NULL, *mask_tensor = NULL, *out = NULL;
    OrtTensorTypeAndShapeInfo *info = NULL; int ok = 0;
    if (!checked(s,s->api->CreateCpuMemoryInfo(OrtArenaAllocator,OrtMemTypeDefault,&memory),error,size)) goto done;
    if (!checked(s,s->api->CreateTensorWithDataAsOrtValue(memory,(void *)input,count*sizeof(float),shape,4,ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT,&in),error,size)) goto done;
    if (mask && !checked(s,s->api->CreateTensorWithDataAsOrtValue(memory,(void *)mask,mask_count*sizeof(float),mask_shape,4,ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT,&mask_tensor),error,size)) goto done;
    const char *inputs[] = {s->input_name,s->mask_name}, *outputs[] = {s->output_name};
    const OrtValue *values[] = {in,mask_tensor};
    if (!checked(s,s->api->Run(s->session,NULL,inputs,values,mask ? 2 : 1,outputs,1,&out),error,size)) goto done;
    if (!checked(s,s->api->GetTensorTypeAndShape(out,&info),error,size)) goto done;
    size_t dims = 0;
    if (!checked(s,s->api->GetDimensionsCount(info,&dims),error,size)) goto done;
    if (dims < 2 || dims > 4) { message(error,size,"Unexpected segmentation output dimensions"); goto done; }
    int64_t actual[4] = {1,1,1,1};
    if (!checked(s,s->api->GetDimensions(info,actual+(4-dims),dims),error,size)) goto done;
    if (!checked(s,s->api->GetTensorShapeElementCount(info,&count),error,size)) goto done;
    if (!count || count > 67108864) { message(error,size,"Segmentation output too large"); goto done; }
    ONNXTensorElementDataType element;
    if (!checked(s,s->api->GetTensorElementType(info,&element),error,size)) goto done;
    void *raw = NULL;
    if (!checked(s,s->api->GetTensorMutableData(out,&raw),error,size)) goto done;
    float *result = malloc(count*sizeof(float));
    if (!result) { message(error,size,"Cannot allocate segmentation output"); goto done; }
    if (element == ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT) memcpy(result,raw,count*sizeof(float));
    else if (element == ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT16) {
        for (size_t i=0;i<count;i++) result[i] = half_float(((uint16_t *)raw)[i]);
    } else { free(result); message(error,size,"Unsupported segmentation output type"); goto done; }
    memcpy(outshape,actual,4*sizeof(int64_t)); *output = result; *output_count = count; ok = 1;
done:
    if (info) s->api->ReleaseTensorTypeAndShapeInfo(info);
    if (out) s->api->ReleaseValue(out);
    if (in) s->api->ReleaseValue(in);
    if (mask_tensor) s->api->ReleaseValue(mask_tensor);
    if (memory) s->api->ReleaseMemoryInfo(memory);
    return ok;
}
int luma_onnx_run(void *opaque, const float *input, const int64_t shape[4], float **output,
                  int64_t outshape[4], size_t *output_count, char *error, size_t size) {
    return run_internal(opaque,input,shape,NULL,NULL,output,outshape,output_count,error,size);
}
int luma_onnx_run_masked(void *opaque, const float *input, const int64_t shape[4], const float *mask, const int64_t mask_shape[4], float **output,
                         int64_t outshape[4], size_t *output_count, char *error, size_t size) {
    if (!mask) { message(error,size,"Missing mask input"); return 0; }
    return run_internal(opaque,input,shape,mask,mask_shape,output,outshape,output_count,error,size);
}
void luma_onnx_free(void *data) { free(data); }
