// Stand-in for the CUDA toolkit's cuda_runtime_api.h, which TensorRT's
// headers include. Meteor uses only the stream and event handle types from
// it (the same opaque pointers as the driver API's CUstream and CUevent),
// so it builds without the CUDA toolkit.
#pragma once
typedef struct CUstream_st* cudaStream_t;
typedef struct CUevent_st* cudaEvent_t;
