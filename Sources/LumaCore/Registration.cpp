// Independent portable Harris / oriented patch / RANSAC registration.
#include "LumaCore.h"
#include <vector>
#include <array>
#include <algorithm>
#include <cmath>
#include <random>
#include <cstring>
namespace {
constexpr double pi=3.14159265358979323846;
struct Feature {double x,y,score;std::array<double,64>d;};
struct Match {double x,y,u,v;}; // moving -> reference
static double sample(const std::vector<double>&g,int w,int h,double x,double y) {
 if(x<0||y<0||x>=w-1||y>=h-1)return 0;
 int a=(int)x,b=(int)y;double u=x-a,v=y-b;
 return (g[b*w+a]*(1-u)+g[b*w+a+1]*u)*(1-v)+(g[(b+1)*w+a]*(1-u)+g[(b+1)*w+a+1]*u)*v;
}
static std::vector<Feature> features(const uint8_t*rgba,int w,int h) {
 std::vector<double>g(w*h),gx(w*h),gy(w*h);
 for(int i=0;i<w*h;++i)g[i]=(rgba[i*4]*.2126+rgba[i*4+1]*.7152+rgba[i*4+2]*.0722)/255.;
 for(int y=1;y<h-1;++y)for(int x=1;x<w-1;++x){gx[y*w+x]=(g[y*w+x+1]-g[y*w+x-1])/2;gy[y*w+x]=(g[(y+1)*w+x]-g[(y-1)*w+x])/2;}
 std::vector<Feature> candidates;
 for(int y=14;y<h-14;y+=2)for(int x=14;x<w-14;x+=2) {
  double a=0,b=0,c=0;
  for(int j=-2;j<=2;++j)for(int i=-2;i<=2;++i){double dx=gx[(y+j)*w+x+i],dy=gy[(y+j)*w+x+i];a+=dx*dx;b+=dy*dy;c+=dx*dy;}
  double score=a*b-c*c-.04*(a+b)*(a+b);
  if(score>1e-7)candidates.push_back({(double)x,(double)y,score,{}});
 }
 std::sort(candidates.begin(),candidates.end(),[](const Feature&a,const Feature&b){return a.score>b.score;});
 std::vector<Feature>out;
 for(auto f:candidates) {
  bool near=false;for(auto &p:out)if(std::hypot(p.x-f.x,p.y-f.y)<9){near=true;break;}if(near)continue;
  // Dominant local gradient direction, weighted to suppress orientation noise.
  double bins[18]={};
  for(int j=-6;j<=6;++j)for(int i=-6;i<=6;++i){int at=((int)f.y+j)*w+(int)f.x+i;double angle=std::atan2(gy[at],gx[at]);int k=(int)((angle+pi)*18/(2*pi))%18;bins[k]+=std::hypot(gx[at],gy[at])*std::exp(-(i*i+j*j)/36.);}
  int peak=(int)(std::max_element(bins,bins+18)-bins);double angle=(peak+.5)*2*pi/18-pi,cs=std::cos(angle),sn=std::sin(angle),mean=0;
  for(int j=0;j<8;++j)for(int i=0;i<8;++i){double xx=(i-3.5)*2,yy=(j-3.5)*2;f.d[j*8+i]=sample(g,w,h,f.x+xx*cs-yy*sn,f.y+xx*sn+yy*cs);mean+=f.d[j*8+i]/64;}
  double norm=0;for(auto &v:f.d){v-=mean;norm+=v*v;}if(norm<1e-7)continue;
  for(auto &v:f.d)v/=std::sqrt(norm);out.push_back(f);if(out.size()>=650)break;
 }
 return out;
}
static bool solve(double a[8][9],double*result) {
 for(int i=0;i<8;++i){int p=i;for(int j=i+1;j<8;++j)if(std::abs(a[j][i])>std::abs(a[p][i]))p=j;
  if(std::abs(a[p][i])<1e-9)return false;for(int j=i;j<9;++j)std::swap(a[i][j],a[p][j]);
  double div=a[i][i];for(int j=i;j<9;++j)a[i][j]/=div;
  for(int k=0;k<8;++k)if(k!=i){double f=a[k][i];for(int j=i;j<9;++j)a[k][j]-=f*a[i][j];}
 }for(int i=0;i<8;++i)result[i]=a[i][8];return true;
}
static bool fit(const std::vector<Match>&m,bool projective,double *H) {
 std::fill(H,H+9,0);H[8]=1;
 if(!projective){
  double x=0,y=0,u=0,v=0;for(auto p:m){x+=p.x;y+=p.y;u+=p.u;v+=p.v;}x/=m.size();y/=m.size();u/=m.size();v/=m.size();
  double a=0,b=0;for(auto p:m){a+=(p.x-x)*(p.u-u)+(p.y-y)*(p.v-v);b+=(p.x-x)*(p.v-v)-(p.y-y)*(p.u-u);}
  double angle=std::atan2(b,a),c=std::cos(angle),s=std::sin(angle);H[0]=c;H[1]=-s;H[2]=u-c*x+s*y;H[3]=s;H[4]=c;H[5]=v-s*x-c*y;return true;
 }
 double normal[8][9]={};
 for(auto p:m){double rows[2][9]={{p.x,p.y,1,0,0,0,-p.u*p.x,-p.u*p.y,p.u},{0,0,0,p.x,p.y,1,-p.v*p.x,-p.v*p.y,p.v}};
 for(auto&r:rows)for(int i=0;i<8;++i)for(int j=0;j<9;++j)normal[i][j]+=r[i]*r[j];}
 return solve(normal,H);
}
static double error(Match p,const double*H){double w=H[6]*p.x+H[7]*p.y+H[8];if(std::abs(w)<1e-9)return 1e9;return std::hypot((H[0]*p.x+H[1]*p.y+H[2])/w-p.u,(H[3]*p.x+H[4]*p.y+H[5])/w-p.v);}
}
extern "C" int luma_register_rgba(const uint8_t*ref,int rw,int rh,const uint8_t*mov,int mw,int mh,int projective,double*matrix) {
 if(!ref||!mov||!matrix||rw<32||rh<32||mw<32||mh<32||rw>2048||rh>2048||mw>2048||mh>2048)return -1;
 auto a=features(ref,rw,rh),b=features(mov,mw,mh);std::vector<Match>matches;
 std::vector<int>reverse(a.size(),-1);std::vector<double>bestReverse(a.size(),1e9);
 for(size_t j=0;j<b.size();++j)for(size_t i=0;i<a.size();++i){double d=0;for(int k=0;k<64;++k)d+=(a[i].d[k]-b[j].d[k])*(a[i].d[k]-b[j].d[k]);if(d<bestReverse[i]){bestReverse[i]=d;reverse[i]=(int)j;}}
 for(size_t j=0;j<b.size();++j){double best=1e9,second=1e9;int index=-1;
  for(size_t i=0;i<a.size();++i){double d=0;for(int k=0;k<64;++k)d+=(a[i].d[k]-b[j].d[k])*(a[i].d[k]-b[j].d[k]);if(d<best){second=best;best=d;index=(int)i;}else second=std::min(second,d);}
  if(index>=0&&best<.75*second&&best<.65&&reverse[index]==(int)j)matches.push_back({b[j].x,b[j].y,a[index].x,a[index].y});
 }
 const int minimum=projective ? 4:2;if((int)matches.size()<std::max(6,minimum))return -2;
 std::mt19937 random(173);int largest=0;double bestH[9]={};std::vector<int>bestIndices;
 for(int iteration=0;iteration<900;++iteration){std::vector<Match>subset;std::vector<int>ids;
  while((int)subset.size()<minimum){int id=random()%matches.size();if(std::find(ids.begin(),ids.end(),id)==ids.end()){ids.push_back(id);subset.push_back(matches[id]);}}
  double H[9];if(!fit(subset,projective,H))continue;std::vector<int>inliers;
  for(size_t i=0;i<matches.size();++i)if(error(matches[i],H)<2.5)inliers.push_back((int)i);
  if((int)inliers.size()>largest){largest=(int)inliers.size();std::copy(H,H+9,bestH);bestIndices=inliers;}
 }
 if(largest<std::max(6,(int)(matches.size()*.22)))return -3;
 std::vector<Match>inliers;for(int i:bestIndices)inliers.push_back(matches[i]);if(!fit(inliers,projective,bestH))return -4;
 for(int i=0;i<9;++i){if(!std::isfinite(bestH[i]))return -4;matrix[i]=bestH[i];}
 return largest;
}
