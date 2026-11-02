#!/usr/bin/python3
"""Host-only slice-parser regression checks; no GPU or headset required."""
import ctypes as c
from pathlib import Path
import subprocess
import tempfile
import re
import unittest

HERE=Path(__file__).resolve().parent
class Config(c.Structure):
    _fields_=[('frame_num_bits',c.c_uint),('poc_type',c.c_uint),('poc_bits',c.c_uint)]+[(n,c.c_bool) for n in ('separate_plane','frame_only','delta_always_zero','bottom_poc','redundant')]
def ue(v):
    bits=bin(v+1)[2:];return '0'*(len(bits)-1)+bits
def slice_nal(kind=0,override=False,pps=0):
    bits=ue(0)+ue(kind)+ue(pps)+'0001'+'0010'
    if kind==1:bits+='1'
    if kind in (0,1,3):bits+='1' if override else '0'
    bits+='1';bits+='0'*((-len(bits))%8)
    return b'\x41'+int(bits,2).to_bytes(len(bits)//8,'big')
class ParserTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp=tempfile.TemporaryDirectory(prefix='nf-avc-parser-')
        root=Path(cls.temp.name)
        (root/'wrapper.c').write_text('#include "h264-reference-defaults.h"\nint probe(const unsigned char *p,size_t n,const struct nf_avc_config *c,bool *b){return nf_avc_uses_defaults(p,n,c,b);}\n')
        subprocess.run(['cc','-Wall','-Wextra','-Werror','-shared','-fPIC','-I',str(HERE),str(root/'wrapper.c'),'-o',str(root/'probe.so')],check=True)
        cls.lib=c.CDLL(str(root/'probe.so'));cls.lib.probe.argtypes=[c.c_void_p,c.c_size_t,c.POINTER(Config),c.POINTER(c.c_bool)];cls.lib.probe.restype=c.c_int
    @classmethod
    def tearDownClass(cls):cls.temp.cleanup()
    def check(self,nal):
        cfg=Config(4,0,4,False,True,False,False,False);is_b=c.c_bool()
        return bool(self.lib.probe(nal,len(nal),c.byref(cfg),c.byref(is_b))),is_b.value
    def test_p_no_override(self):self.assertEqual(self.check(slice_nal()),(True,False))
    def test_b_no_override(self):self.assertEqual(self.check(slice_nal(1)),(True,True))
    def test_override_not_a_default(self):
        for kind in (0,1,3):self.assertFalse(self.check(slice_nal(kind,True))[0])
    def test_intra_not_a_default(self):self.assertFalse(self.check(slice_nal(2))[0])
    def test_other_pps_not_assumed(self):self.assertFalse(self.check(slice_nal(pps=1))[0])
    def test_truncated_or_malformed(self):
        for nal in (b'',b'\x41',b'\x41\0',b'\x41'+b'\0'*256,b'\x67\xff'):
            self.assertFalse(self.check(nal)[0])
    def test_generated_clip_against_ffmpeg_header_parser(self):
        clip=HERE.parents[2]/'.build-cache/browser-quest-linux/generated-original-60.h264'
        if not clip.exists():self.skipTest('Optional generated clip not present')
        run=subprocess.run(['ffmpeg','-hide_banner','-loglevel','info','-i',str(clip),'-c','copy','-bsf:v','trace_headers','-f','null','-'],capture_output=True,text=True,check=True,timeout=10)
        blocks=[];current=None
        for line in run.stderr.splitlines():
            if 'Slice Header' in line:
                current={};blocks.append(current)
            if current is not None:
                match=re.search(r'\b(slice_type|num_ref_idx_active_override_flag)\s+.*= (\d+)$',line)
                if match:current[match[1]]=int(match[2])
        nals=[n for n in re.split(b'\x00\x00\x00?\x01',clip.read_bytes()) if n and n[0]&31 in (1,5)]
        self.assertEqual(len(blocks),len(nals));self.assertEqual(len(nals),60)
        cfg=Config(4,0,6,False,True,False,False,False)
        for nal,values in zip(nals,blocks):
            is_b=c.c_bool()
            actual=bool(self.lib.probe(nal,len(nal),c.byref(cfg),c.byref(is_b)))
            kind=values['slice_type']%5
            expected=kind in (0,1,3) and values.get('num_ref_idx_active_override_flag')==0
            self.assertEqual(actual,expected)
if __name__=='__main__':unittest.main()
