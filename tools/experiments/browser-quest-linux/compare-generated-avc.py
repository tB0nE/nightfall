#!/usr/bin/python3
"""Offline experiment: restore ORIGINAL PPS list defaults in a generated capture.
Not a general streaming fix: requires the original known-clear test bitstream.
No decoder setting or installed driver changes.
"""
import argparse
import json
from pathlib import Path
import re

def nalus(data):
    return [part for part in re.split(b'\x00\x00\x00?\x01',data) if part]

def rbsp(data):
    out=bytearray();zeros=0
    for byte in data:
        if zeros==2 and byte==3: zeros=0;continue
        out.append(byte);zeros=zeros+1 if byte==0 else 0
    return bytes(out)

def escape(data):
    out=bytearray();zeros=0
    for byte in data:
        if zeros>=2 and byte<=3:out.append(3);zeros=0
        out.append(byte);zeros=zeros+1 if byte==0 else 0
    return bytes(out)

def defaults(nal):
    if nal[0]&31!=8:raise ValueError('Not a PPS')
    bits=''.join(f'{b:08b}' for b in rbsp(nal[1:]));position=0
    def ue():
        nonlocal position
        start=position
        while position<len(bits) and bits[position]=='0':position+=1
        zeros=position-start
        if position+zeros>=len(bits):raise ValueError('Truncated PPS')
        position+=zeros+1
        return int(bits[start+zeros:position],2)-1
    pps_id=ue();sps_id=ue();position+=2
    if ue()!=0:raise ValueError('Slice groups not supported by this diagnostic')
    start=position;l0=ue();l1=ue()
    return bits,start,position,l0,l1,pps_id,sps_id

def encode_ue(value):
    b=bin(value+1)[2:];return '0'*(len(b)-1)+b

def repair(original,captured):
    original_pps=next(n for n in nalus(original) if n[0]&31==8)
    _,_,_,l0,l1,pps_id,sps_id=defaults(original_pps)
    result=[];changes=[]
    for n in nalus(captured):
        if n[0]&31==8:
            bits,start,end,old0,old1,pid,sid=defaults(n)
            if (pid,sid)!=(pps_id,sps_id):raise ValueError('Different PPS/SPS identifiers')
            bits=(bits[:start]+encode_ue(l0)+encode_ue(l1)+bits[end:]).rstrip('0')
            bits+='0'*((-len(bits))%8)
            n=n[:1]+escape(int(bits,2).to_bytes(len(bits)//8,'big'))
            changes.append({'old_l0_minus1':old0,'old_l1_minus1':old1,'original_l0_minus1':l0,'original_l1_minus1':l1})
        result.append(b'\x00\x00\x00\x01'+n)
    return b''.join(result),changes

def main():
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('original',type=Path);p.add_argument('capture',type=Path);p.add_argument('output',type=Path);a=p.parse_args()
    output,changes=repair(a.original.read_bytes(),a.capture.read_bytes());a.output.write_bytes(output)
    print(json.dumps({'output':str(a.output),'pps_changes':changes},indent=2))
if __name__=='__main__':main()
