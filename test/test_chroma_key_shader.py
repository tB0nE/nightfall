#!/usr/bin/env python3
"""Render the production chroma-key function under software OpenGL; no headset/GPU UI."""
import argparse
import ast
import json
import os
from pathlib import Path
import re
import struct

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, default=ROOT/'build/verify/chroma-key-shader')
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    mesa = Path('/usr/share/glvnd/egl_vendor.d/50_mesa.json')
    if not mesa.exists():
        raise SystemExit('Mesa EGL is required for this software-only shader test')
    os.environ['__EGL_VENDOR_LIBRARY_FILENAMES'] = str(mesa)
    os.environ['LIBGL_ALWAYS_SOFTWARE'] = '1'
    os.environ['MESA_SHADER_CACHE_DIR'] = '/tmp/nightfall-chroma-shader-cache'
    import moderngl
    context = moderngl.create_standalone_context(backend='egl', require=330)
    renderer = context.info['GL_RENDERER']
    assert any(s in renderer.lower()for s in ['llvmpipe','softpipe','software']), renderer
    shared = (ROOT/'src/shaders/chroma_key.gdshaderinc').read_text()
    program = context.program(vertex_shader='''#version 330
void main() {
    vec2 p = vec2((gl_VertexID == 1) ? 3.0 : -1.0, (gl_VertexID == 2) ? 3.0 : -1.0);
    gl_Position = vec4(p, 0.0, 1.0);
}''', fragment_shader='''#version 330
uniform vec4 color;
uniform vec3 key;
uniform float tolerance;
out vec4 result;
'''+shared+'''
void main() { result = nightfall_chroma_key(color, key, tolerance); }
''')
    target = context.simple_framebuffer((1,1), components=4, dtype='f4')
    target.use()
    vao = context.vertex_array(program, [])
    def render(c, key=(0.,1.,0.), tolerance=.16):
        program['color'].value = c
        program['key'].value = key
        program['tolerance'].value = tolerance
        vao.render(vertices=3)
        return struct.unpack('4f',target.read(components=4,dtype='f4'))
    cases = []
    for name,key in [('green',(0.,1.,0.)),('blue',(0.,0.,1.)),('magenta',(1.,0.,1.))]:
        for brightness in [1., .45, .08]:
            c=tuple(v*brightness for v in key)+(1.,)
            got=render(c,key)
            assert got[3]<1e-5,(name,brightness,got)
            cases.append(dict(name=f'{name}-{brightness}',input=c,output=got))
    for name,c in [('white',(1.,1.,1.,1.)),('grey',(.2,.2,.2,1.)),('black',(0.,0.,0.,1.)),('red',(1.,0.,0.,1.)),('yellow',(1.,1.,0.,1.)),('transparent-red',(1.,0.,0.,.4))]:
        got=render(c)
        assert max(abs(a-b)for a,b in zip(c,got))<1e-5,(name,got)
        cases.append(dict(name=name,input=c,output=got))
    edge=(.7,1.,.7,1.)
    results=[render(edge,tolerance=t)for t in [.08,.16,.26]]
    assert results[0][3]>results[1][3]>results[2][3],results
    assert all(abs(c[1]-c[0])<1e-5 and abs(c[1]-c[2])<1e-5 for c in results),results
    assert render((.2,1.2,.2,1.),key=(.2,1.2,.2))[3]<1e-5
    cases.append(dict(name='soft-edge-tolerance',input=edge,outputs=results))
    # Save the exact expanded native shaders for glslang or GLES-driver checks.
    native=(ROOT/'extensions/nightfall-xr/src/fast_xr_renderer_android.cpp').read_text()
    for name,end in [('FRAGMENT_SRC','HDR_FRAGMENT_SRC'),('HDR_FRAGMENT_SRC','pq_decode_lut')]:
        start=native.index('static const char *'+name)
        stop=native.index(end,start+30)
        shader=''.join(ast.literal_eval(m.group(1))for line in native[start:stop].splitlines()if(m:=re.match(r'^\s*("(?:[^"\\]|\\.)*")\s*;?\s*$',line)))
        shader=shader.replace('// NIGHTFALL_CHROMA_KEY_INCLUDE',shared)
        assert 'nightfall_chroma_key(fragColor' in shader
        for picture in [False,True]:
            first,rest=shader.split('\n',1)
            source=first+'\n#define NIGHTFALL_TEXTURE_2D\n'+('#define NIGHTFALL_PICTURE\n'if picture else'')+rest
            (args.output/(name+('-picture'if picture else'')+'.frag')).write_text(source)
    summary=dict(ok=True,renderer=renderer,cases=cases,native_shader_variants=4)
    (args.output/'summary.json').write_text(json.dumps(summary,indent=2)+'\n')
    print(json.dumps(dict(ok=True,renderer=renderer,cases=len(cases),summary=str(args.output/'summary.json'))))
    vao.release();target.release();program.release();context.release()


if __name__ == '__main__':
    main()
