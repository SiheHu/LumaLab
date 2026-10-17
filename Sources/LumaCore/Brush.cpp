#include "LumaCore.h"
#include <algorithm>
#include <cmath>
#include <limits>
extern "C" uint32_t luma_core_version(void) { return 1; }
extern "C" void luma_brush_segment(uint8_t *out, int w, int h, double ax, double ay,
                                   double bx, double by, double r, double feather) {
    if (!out || w < 1 || h < 1 || w > 32768 || h > 32768 ||
        !std::isfinite(ax) || !std::isfinite(ay) || !std::isfinite(bx) ||
        !std::isfinite(by) || !std::isfinite(r) || !std::isfinite(feather)) return;
    r = std::max(0.5, std::min(r, double(std::max(w,h)) * 3));
    feather = std::max(0.0, std::min(1.0, feather));
    const double inner = r * (1.0 - feather);
    const double span = std::max(1.0, r - inner);
    const int x0 = int(std::max(0.0, std::min(double(w), std::floor(std::min(ax,bx)-r-1))));
    const int y0 = int(std::max(0.0, std::min(double(h), std::floor(std::min(ay,by)-r-1))));
    const int x1 = int(std::max(0.0, std::min(double(w), std::ceil(std::max(ax,bx)+r+1))));
    const int y1 = int(std::max(0.0, std::min(double(h), std::ceil(std::max(ay,by)+r+1))));
    const double dx = bx-ax, dy = by-ay, length2 = dx*dx+dy*dy;
    for (int y=y0; y<y1; ++y) for (int x=x0; x<x1; ++x) {
        double t = length2 > 1e-12 ? ((x+0.5-ax)*dx+(y+0.5-ay)*dy)/length2 : 0;
        t = std::max(0.0,std::min(1.0,t));
        const double distance = std::hypot(x+0.5-ax-t*dx,y+0.5-ay-t*dy);
        const double value = feather > 0 ? (r-distance)/span : r+0.5-distance;
        const auto weight = uint8_t(std::lround(std::max(0.0,std::min(1.0,value))*255));
        out[size_t(y)*w+x] = std::max(out[size_t(y)*w+x],weight);
    }
}
