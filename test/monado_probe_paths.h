#pragma once
#include <stdio.h>
#include <stdlib.h>
// Diagnostic paths only, one caller thread per process. No installed/runtime config.
static const char *meteor_probe_path(const char *leaf)
{
    static char path[4096];
    const char *root = getenv("METEOR_PROBE_OUTPUT");
    snprintf(path, sizeof(path), "%s/%s", root ? root : "/out", leaf);
    return path;
}
