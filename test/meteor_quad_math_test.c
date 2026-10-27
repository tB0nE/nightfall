#include "meteor_quad_math.h"
#include <assert.h>
#include <stdio.h>
int main(void) {
    float pose[7]={0,0,-2,0,0,0,1},size[2]={1,1},head[3]={0,0,0};
    float view[11]={0,0,0,0,0,0,1,-.785398163f,.785398163f,.785398163f,-.785398163f},clip[4];
    meteor_quad_corner(pose,size,view,head,false,0,clip);
    assert(fabsf(clip[0]+.5f)<.0001f && fabsf(clip[1]+.5f)<.0001f && clip[3]==2);
    assert(clip[2]>0 && clip[2]<clip[3]);
    meteor_quad_corner(pose,size,view,head,false,3,clip);
    assert(fabsf(clip[0]-.5f)<.0001f && fabsf(clip[1]-.5f)<.0001f);
    // Head translation cancels for VIEW-space layers but not world layers.
    view[0]=head[0]=10;
    meteor_quad_corner(pose,size,view,head,true,0,clip);
    assert(fabsf(clip[0]+.5f)<.0001f);
    meteor_quad_corner(pose,size,view,head,false,0,clip);
    assert(fabsf(clip[0]+10.5f)<.0001f);
    // Stereo keeps the eye offset even for head-locked layers.
    view[0]+=.032f;
    meteor_quad_corner(pose,size,view,head,true,0,clip);
    assert(fabsf(clip[0]+.532f)<.0001f);
    // A 180-degree head rotation transforms a world quad behind the viewer.
    view[0]=head[0]=0; view[4]=1; view[6]=0;
    meteor_quad_corner(pose,size,view,head,false,0,clip);
    assert(clip[3]<0);
    float panorama[7]={0,0,0,0,0,0,1},rays[4][4],origin[4];
    meteor_panorama_rays(panorama,view,head,false,rays,origin);
    // Current head faces backward: top-left local ray is rotated 180 degrees.
    assert(fabsf(rays[0][0]-1)<.0001f && fabsf(rays[0][2]-1)<.0001f);
    meteor_panorama_rays(panorama,view,head,true,rays,origin);
    assert(fabsf(rays[0][0]+1)<.0001f && fabsf(rays[0][1]-1)<.0001f && rays[0][2]==-1);
    assert(sizeof(struct meteor_quad_push)==128);
    float actual_head[7]={10,2,0,0,1,0,0},local_pose[7]={0,0,-2,0,0,0,1},world_pose[7];
    meteor_layer_world_pose(local_pose,actual_head,true,world_pose);
    assert(fabsf(world_pose[0]-10)<.0001f && world_pose[1]==2 && world_pose[2]==2);
    assert(world_pose[4]==1 && world_pose[6]==0);
    meteor_layer_world_pose(local_pose,actual_head,false,world_pose);
    assert(world_pose[0]==0 && world_pose[2]==-2 && world_pose[6]==1);
    puts("PASS: quad projection, view space, stereo offset and Vulkan clip convention");
}
