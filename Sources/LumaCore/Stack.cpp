#include "LumaCore.h"
#include <array>
#include <algorithm>
#include <cmath>
extern "C" float luma_sigma_mean(const float *values,int count,float sigma) {
 if(!values||count<1||count>32)return 0;
 std::array<float,32>a{},deviation{};int n=0;
 for(int i=0;i<count;++i)if(std::isfinite(values[i]))a[n++]=values[i];if(!n)return 0;
 std::sort(a.begin(),a.begin()+n);
 const float median=n%2 ? a[n/2]:(a[n/2-1]+a[n/2])*.5f;
 for(int i=0;i<n;++i)deviation[i]=std::abs(a[i]-median);
 std::sort(deviation.begin(),deviation.begin()+n);
 const float mad=n%2 ? deviation[n/2]:(deviation[n/2-1]+deviation[n/2])*.5f;
 const float threshold=std::max(.002f,std::max(0.f,sigma)*1.4826f*mad);
 float sum=0;int kept=0;for(int i=0;i<n;++i)if(std::abs(a[i]-median)<=threshold){sum+=a[i];++kept;}
 return kept ? sum/kept:median;
}
