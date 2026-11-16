Copy of vcpkg's `ffmpeg` port at the baseline in `../../vcpkg-configuration.json`
(026ac03d99ca88e45b5f260267b22e103ec05ec0, FFmpeg 7.1.2), with one change in
`portfile.cmake`: `--enable-v4l2-m2m` on Linux, so the V4L2 mem2mem hardware
decoders exist (Steam Frame / other Linux ARM headsets). `port-version` is bumped
so the change gets a distinct ABI hash. Re-copy the port when the baseline moves.
