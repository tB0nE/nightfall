#include "meteor_foveated_qp.h"
#include <cassert>
int main() {
    for(uint32_t block : {16u,32u}) {
        auto map=meteor_foveated_qp(512,768,block);
        uint32_t columns=1024/block,rows=768/block;
        assert(map.size()==columns*rows);
        assert(map[(rows/2)*columns+columns/4]==-2);
        assert(map[(rows/2)*columns+columns*3/4]==-2);
        assert(map[(rows/2)*columns]>0 && map[(rows/2)*columns+columns/2]>0);
        for(uint32_t y=0;y<rows;++y) for(uint32_t x=0;x<columns/2;++x) {
            assert(map[y*columns+x]==map[y*columns+x+columns/2]);
            assert(map[y*columns+x]==map[(rows-1-y)*columns+x]);
            assert(map[y*columns+x]>=-2 && map[y*columns+x]<=6);
        }
    }
    assert(meteor_foveated_qp(528,752,32).size()==33*24);
    assert(meteor_foveated_qp(0,768,32).empty());
    assert(meteor_foveated_qp(512,768,64).empty());
}
