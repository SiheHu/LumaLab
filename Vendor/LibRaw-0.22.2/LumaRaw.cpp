// LumaLab adapter. LibRaw upstream files are unmodified; see LICENSE.CDDL / LICENSE.LGPL.
#include "libraw/libraw.h"
#include "luma-include/LumaRaw.h"
#include <cstring>
#include <cstdlib>
#include <cstdio>
#include <memory>
extern "C" int luma_raw_decode(const void *data,size_t length,LumaRawImage *out,char *error,size_t error_size) {
 if(!data || !out || !length || length>1024ull*1024*1024) return -1;
 std::memset(out,0,sizeof(*out));
 try {
  auto raw=std::make_unique<LibRaw>();
  raw->imgdata.rawparams.max_raw_memory_mb=2048;
  int status=raw->open_buffer(const_cast<void*>(data),length);
  if(!status && (size_t)raw->imgdata.sizes.width*raw->imgdata.sizes.height>100000000) status=-1;
  if(!status) status=raw->unpack();
  raw->imgdata.params.output_bps=16;raw->imgdata.params.output_color=1;
  raw->imgdata.params.gamm[0]=1;raw->imgdata.params.gamm[1]=1;
  raw->imgdata.params.use_camera_wb=1;raw->imgdata.params.no_auto_bright=1;
  raw->imgdata.params.user_qual=3;
  if(!status) status=raw->dcraw_process();
  libraw_processed_image_t *image=nullptr;
  if(!status) image=raw->dcraw_make_mem_image(&status);
  if(status || !image) {if(error&&error_size)std::snprintf(error,error_size,"%s",libraw_strerror(status));return status ? status:-1;}
  if(image->type!=LIBRAW_IMAGE_BITMAP || image->bits!=16 || image->colors!=3 || image->width==0 || image->height==0 || (size_t)image->width*image->height>100000000 || image->data_size!=(size_t)image->width*image->height*6) {
   LibRaw::dcraw_clear_mem(image);return -1;
  }
  out->width=image->width;out->height=image->height;out->count=(size_t)image->width*image->height*3;
  out->rgb=(uint16_t*)std::malloc(out->count*sizeof(uint16_t));
  if(!out->rgb) {LibRaw::dcraw_clear_mem(image);return -1;}
  std::memcpy(out->rgb,image->data,out->count*2);LibRaw::dcraw_clear_mem(image);
  out->iso=raw->imgdata.other.iso_speed;out->shutter=raw->imgdata.other.shutter;
  out->aperture=raw->imgdata.other.aperture;out->focal=raw->imgdata.other.focal_len;
  std::snprintf(out->make,sizeof(out->make),"%s",raw->imgdata.idata.make);
  std::snprintf(out->model,sizeof(out->model),"%s",raw->imgdata.idata.model);
  return 0;
 } catch(...) {if(error&&error_size)std::snprintf(error,error_size,"RAW decode failed");return -1;}
}
extern "C" void luma_raw_free(LumaRawImage *image) {if(image){std::free(image->rgb);image->rgb=nullptr;}}
extern "C" const char *luma_raw_version(void) {return LIBRAW_VERSION_STR;}
