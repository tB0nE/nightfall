/* Experimental Nightfall Xvfb capture. SPDX-License-Identifier: MIT */
/* Included from glamor_transfer.c; all resources belong to the server context. */
struct nf_capture_slot { GLuint buffer; GLsync fence; uint64_t sequence; };
struct nf_capture_state {
    struct nf_capture_slot slots[2];
    int width, height;
    size_t size;
    uint64_t sequence;
    uint64_t read_us, map_us, copy_us, copies;
};
static struct nf_capture_state nf_capture[MAXSCREENS];

_X_EXPORT Bool
glamor_nf_capture(ScreenPtr screen, PixmapPtr pixmap, uint8_t *destination)
{
    glamor_screen_private *gp = glamor_get_screen_private(screen);
    struct nf_capture_state *state = &nf_capture[screen->myNum];
    glamor_make_current(gp);
    if (!pixmap || state->width != pixmap->drawable.width ||
        state->height != pixmap->drawable.height) {
        for (int i = 0; i < 2; i++) {
            if (state->slots[i].fence) glDeleteSync(state->slots[i].fence);
            if (state->slots[i].buffer) glDeleteBuffers(1, &state->slots[i].buffer);
        }
        if (state->sequence) ErrorF("NF capture: submissions=%llu copies=%llu read_us=%llu map_us=%llu copy_us=%llu\n", (unsigned long long)state->sequence, (unsigned long long)state->copies, (unsigned long long)state->read_us, (unsigned long long)state->map_us, (unsigned long long)state->copy_us);
        memset(state, 0, sizeof(*state));
    }
    if (!pixmap) return TRUE;
    glamor_pixmap_private *priv = glamor_get_pixmap_private(pixmap);
    const struct glamor_format *format = glamor_format_for_pixmap(pixmap);
    if (!priv || priv->block_wcnt != 1 || priv->block_hcnt != 1 ||
        (PICT_FORMAT_BPP(format->render_format) != 32) ||
        epoxy_gl_version() < 30)
        return FALSE;
    glamor_pixmap_fbo *fbo = glamor_pixmap_fbo_at(priv, 0);
    if (!fbo || !fbo->fb) return FALSE;
    state->width = pixmap->drawable.width;
    state->height = pixmap->drawable.height;
    state->size = (size_t)state->width * state->height * 4;
    /* Consume in submission order, without blocking on an unfinished fence. */
    for (int pass = 0; pass < 2; pass++) {
        int oldest = -1;
        for (int i = 0; i < 2; i++)
            if (state->slots[i].fence && (oldest < 0 ||
                state->slots[i].sequence < state->slots[oldest].sequence)) oldest = i;
        if (oldest < 0) break;
        struct nf_capture_slot *slot = &state->slots[oldest];
        GLenum ready = glClientWaitSync(slot->fence, 0, 0);
        if (ready != GL_ALREADY_SIGNALED && ready != GL_CONDITION_SATISFIED) break;
        glBindBuffer(GL_PIXEL_PACK_BUFFER, slot->buffer);
        CARD64 map_start = GetTimeInMicros();
        void *mapped = glMapBufferRange(GL_PIXEL_PACK_BUFFER, 0, state->size, GL_MAP_READ_BIT);
        state->map_us += GetTimeInMicros() - map_start;
        if (mapped) {
            CARD64 copy_start = GetTimeInMicros();
            memcpy(destination, mapped, state->size);
            state->copy_us += GetTimeInMicros() - copy_start;
            glUnmapBuffer(GL_PIXEL_PACK_BUFFER);
        }
        state->copies++;
        glBindBuffer(GL_PIXEL_PACK_BUFFER, 0);
        glDeleteSync(slot->fence); slot->fence = NULL;
    }
    for (int i = 0; i < 2; i++) {
        struct nf_capture_slot *slot = &state->slots[i];
        if (slot->fence) continue;
        if (!slot->buffer) {
            glGenBuffers(1, &slot->buffer);
            glBindBuffer(GL_PIXEL_PACK_BUFFER, slot->buffer);
            Bool coherent = getenv("NF_KGSL_COHERENT_READBACK") != NULL;
            Bool arb = epoxy_has_gl_extension("GL_ARB_buffer_storage");
            Bool ext = epoxy_has_gl_extension("GL_EXT_buffer_storage");
            ErrorF("NF capture storage: coherent=%d arb=%d ext=%d\n", coherent, arb, ext);
            if (coherent && arb)
                glBufferStorage(GL_PIXEL_PACK_BUFFER, state->size, NULL,
                    GL_MAP_READ_BIT | GL_MAP_PERSISTENT_BIT | GL_MAP_COHERENT_BIT);
            else if (coherent && ext)
                glBufferStorageEXT(GL_PIXEL_PACK_BUFFER, state->size, NULL,
                    GL_MAP_READ_BIT | GL_MAP_PERSISTENT_BIT | GL_MAP_COHERENT_BIT);
            else
                glBufferData(GL_PIXEL_PACK_BUFFER, state->size, NULL, GL_STREAM_READ);
        } else glBindBuffer(GL_PIXEL_PACK_BUFFER, slot->buffer);
        glBindFramebuffer(GL_FRAMEBUFFER, fbo->fb);
        glPixelStorei(GL_PACK_ALIGNMENT, 4);
        if (gp->has_pack_subimage) glPixelStorei(GL_PACK_ROW_LENGTH, 0);
        CARD64 read_start = GetTimeInMicros();
        glReadPixels(0, 0, state->width, state->height, format->format, format->type, NULL);
        state->read_us += GetTimeInMicros() - read_start;
        slot->fence = glFenceSync(GL_SYNC_GPU_COMMANDS_COMPLETE, 0);
        slot->sequence = ++state->sequence;
        glBindBuffer(GL_PIXEL_PACK_BUFFER, 0);
        glFlush();
        break;
    }
    return TRUE;
}
