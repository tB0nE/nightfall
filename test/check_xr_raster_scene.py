"""Decoded raster-scene smoke checks, not an independent pixel/depth oracle."""


def validate_raster_scene(rgb: bytes, eye_size: int, frames: int):
    frame_bytes=eye_size*eye_size*6
    if eye_size not in (256,512) or frames<2 or len(rgb)!=frame_bytes*frames:
        raise ValueError("Raster smoke check requires at least two complete stereo frames")
    def samples(frame,eye):
        base=frame*frame_bytes
        return [tuple(rgb[base+(y*eye_size*2+eye*eye_size+x)*3:
                          base+(y*eye_size*2+eye*eye_size+x)*3+3])
                for y in range(4,eye_size,8) for x in range(4,eye_size,8)]
    left=samples(0,0); right=samples(0,1); last=samples(frames-1,0)
    for eye in (left,right):
        colored=sum(max(pixel)-min(pixel)>30 and max(pixel)>65 for pixel in eye)
        gray=sum(max(pixel)-min(pixel)<12 and 15<sum(pixel)/3<80 for pixel in eye)
        dark=sum(max(pixel)<40 for pixel in eye)
        if colored<8 or gray<8 or dark<8:
            raise ValueError("Raster scene lacks colored geometry, floor or dark background")
    def changed(a,b):
        return sum(max(abs(x-y) for x,y in zip(p,q))>12 for p,q in zip(a,b))
    if changed(left,right)<5:
        raise ValueError("Raster stereo eyes unexpectedly identical")
    if changed(left,last)<5:
        raise ValueError("Raster scene unexpectedly static")
