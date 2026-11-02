#!/usr/bin/python3
"""Generated Android-owned RGBA dma-buf rendered by Linux Mesa, read on Android."""
import array
import importlib.util
import json
import os
import signal
import socket
import struct
signal.alarm(5)
result={'passed':False};fds=[]
try:
    spec=importlib.util.spec_from_file_location('paint','/tmp/paint-generated-dmabuf.py')
    paint=importlib.util.module_from_spec(spec);spec.loader.exec_module(paint)
    pixels=[]
    with socket.socket(socket.AF_UNIX,socket.SOCK_SEQPACKET) as connection:
        connection.settimeout(2);connection.connect('/tmp/nf-gpu.sock')
        header=connection.recv(16)
        if len(header)!=16:raise RuntimeError('Native header missing')
        magic,width,height,stride=struct.unpack('=4I',header)
        if magic!=0x4e464142 or (width,height) not in ((128,128),(1280,720)) or not width*4<=stride<=8192:raise RuntimeError('Unexpected generated layout')
        # The flattened gralloc metadata is opaque: retain/close all handles,
        # identify only the generated pixel allocation by its advertised size.
        for attempt in range(3):
            payload,controls,flags,_=connection.recvmsg(65536,socket.CMSG_SPACE(16*4))
            if flags&(socket.MSG_CTRUNC|socket.MSG_TRUNC):raise RuntimeError('Truncated native handle')
            for level,kind,data in controls:
                if level==socket.SOL_SOCKET and kind==socket.SCM_RIGHTS:
                    received=array.array('i');received.frombytes(data[:len(data)//4*4]);fds.extend(received)
            if fds:break
        sizes=[os.fstat(fd).st_size for fd in fds];result['fd_sizes']=sizes
        candidates=[fd for fd,size in zip(fds,sizes) if size>=stride*height]
        if len(candidates)!=1:raise RuntimeError('Cannot identify generated pixel allocation')
        for i,color in enumerate([(1,0,0,1),(0,1,0,1),(0,0,1,1)]):
            pixels.append(paint.paint(candidates[0],stride,width,height,color,0x34324241))
            connection.sendall(str(i).encode())
            if connection.recv(1)!=b'K':raise RuntimeError('Android frame check failed')
    result.update(width=width,height=height,passed=all(p[i]==255 and p[(i+1)%3]==0 and p[(i+2)%3]==0 for i,p in enumerate(pixels)),producer_pixels=pixels,stride=stride)
except Exception as error:result['error']=type(error).__name__+': '+str(error)
finally:
    for fd in fds:os.close(fd)
print(json.dumps(result))
raise SystemExit(0 if result['passed'] else 1)
