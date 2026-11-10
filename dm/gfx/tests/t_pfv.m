#include "../nvn/nvn_mtl.m"

void *front_metal_layer(void) { return NULL; }
module_t *module_of(const void *p) { (void)p; return NULL; }
module_t *g_mod; int g_nmod;
void svc_thread_dump(void) {}
uint64_t now_ns(void) { return bp_now(); }

// A colour render target view of another class (R32_UI) over a colour texture of the same texel size. Nintendo Switch Sports Resort's NDSR upscaler input is an RGB9E5F texture
// written through an R32_UI view by a fragment shader whose output is the packed bits as uint: attach attaches the R32Uint view, so the pipeline takes the uint output and the stored
// bits are the shader's (before, the base RGB9E5Float texture was attached, the shader's float entry wrote the bits' float value, and the upscaled picture came out red). An RGB9E5F
// texture has the format-view usage from its creation; another format is upgraded to it at its first such pass. Returns the number of failed checks
static int rt_view_into(int nvn_format, MTLPixelFormat want_base, uint64_t serial, int made_with_pfv) {
    int failed = 0;
    tex_t e = {.magic = MAGIC('T', 'E', 'X', 0), .serial = serial};
    e.d.width = 4; e.d.height = 1; e.d.depth = 1; e.d.levels = 1; e.d.target = NVN_TEXTURE_TARGET_2D; e.d.format = nvn_format;
    MTLTextureDescriptor *d = tex_desc(&e, 0);
    failed += !!(d.usage & MTLTextureUsagePixelFormatView) != made_with_pfv;
    serial_put(e.serial, [g_dev newTextureWithDescriptor:d]);
    view_t v = {0}; v.set_format = 1; v.format = NVN_FORMAT_R32UI;
    MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
    uint64_t upgrades = g_pfv_upgrades;
    mtl_sub_begin();
    attach(rp.colorAttachments[0], &e, &v, 1);
    if (g_blit) { enc_b_end(g_blit); g_blit = nil; }
    id<MTLTexture> base = serial_get(e.serial), att = rp.colorAttachments[0].texture;
    failed += g_pfv_upgrades - upgrades != (uint64_t)!made_with_pfv;   // upgraded only when made without the usage
    failed += att.pixelFormat != MTLPixelFormatR32Uint;
    failed += att.parentTexture != base;                                 // a view of the registered texture, whose bits the game later samples in the base format
    failed += base.pixelFormat != want_base || !(base.usage & MTLTextureUsagePixelFormatView);
    // A packed RGB9E5 word drawn through the attachment as uint is stored as it is
    NSString *src = @"#include <metal_stdlib>\nusing namespace metal;\nstruct O { float4 p [[position]]; };\n"
                     "vertex O vs(uint i [[vertex_id]]) { O o; float2 q = float2((i << 1) & 2, i & 2); o.p = float4(q * 2 - 1, 0, 1); return o; }\n"
                     "fragment uint4 fs() { return uint4(0x7c0203ffu, 0, 0, 0); }\n";
    NSError *err = nil; id<MTLLibrary> lib = [g_dev newLibraryWithSource:src options:nil error:&err];
    MTLRenderPipelineDescriptor *pd = [MTLRenderPipelineDescriptor new];
    pd.vertexFunction = [lib newFunctionWithName:@"vs"]; pd.fragmentFunction = [lib newFunctionWithName:@"fs"]; pd.colorAttachments[0].pixelFormat = att.pixelFormat;
    id<MTLRenderPipelineState> ps = lib ? [g_dev newRenderPipelineStateWithDescriptor:pd error:&err] : nil;
    failed += !ps;
    mtl_sub_commit(); mtl_drain();
    if (ps) {
        id<MTLCommandQueue> q = [g_dev newCommandQueue]; id<MTLCommandBuffer> cb = [q commandBuffer];
        rp.colorAttachments[0].loadAction = MTLLoadActionClear; rp.colorAttachments[0].storeAction = MTLStoreActionStore;
        id<MTLRenderCommandEncoder> en = [cb renderCommandEncoderWithDescriptor:rp];
        [en setRenderPipelineState:ps]; [en drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3]; [en endEncoding];
        id<MTLBuffer> out = [g_dev newBufferWithLength:16 options:MTLResourceStorageModeShared];
        id<MTLBlitCommandEncoder> b = [cb blitCommandEncoder];
        [b copyFromTexture:base sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0) sourceSize:MTLSizeMake(4, 1, 1) toBuffer:out destinationOffset:0 destinationBytesPerRow:16 destinationBytesPerImage:16];
        [b endEncoding]; [cb commit]; [cb waitUntilCompleted];
        const uint32_t *w = out.contents; for (int i = 0; i < 4; i++) failed += w[i] != 0x7c0203ffu;
    }
    printf("R32_UI render target view of NVN format %#x: failed=%d\n", nvn_format, failed);
    return failed;
}
static int rt_view_class_change(void) {
    int failed = rt_view_into(NVN_FORMAT_RGB9E5F, MTLPixelFormatRGB9E5Float, 70002, 1) + rt_view_into(NVN_FORMAT_RG16F, MTLPixelFormatRG16Float, 70003, 0);
    // Another texel size (R32_UI over RGBA16F): no Metal view bridges them, the texture is left as it was
    tex_t h = {.magic = MAGIC('T', 'E', 'X', 0), .serial = 70004};
    h.d.width = 4; h.d.height = 1; h.d.depth = 1; h.d.levels = 1; h.d.target = NVN_TEXTURE_TARGET_2D; h.d.format = NVN_FORMAT_RGBA16F;
    serial_put(h.serial, [g_dev newTextureWithDescriptor:tex_desc(&h, 0)]);
    view_t v = {0}; v.set_format = 1; v.format = NVN_FORMAT_R32UI;
    MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
    mtl_sub_begin();
    attach(rp.colorAttachments[0], &h, &v, 1);
    if (g_blit) { enc_b_end(g_blit); g_blit = nil; }
    failed += rp.colorAttachments[0].texture.pixelFormat != MTLPixelFormatRGBA16Float || (((id<MTLTexture>)serial_get(h.serial)).usage & MTLTextureUsagePixelFormatView);
    mtl_sub_commit(); mtl_drain();
    return failed;
}

int main(void) {
    int failed = 0;
    failed += tex_need_pfv(MTLPixelFormatRGBA8Unorm, MTLPixelFormatRGBA8Unorm) != 0;
    failed += tex_need_pfv(MTLPixelFormatRGBA8Unorm, MTLPixelFormatRGBA8Unorm_sRGB) != 0;
    failed += tex_need_pfv(MTLPixelFormatBGRA8Unorm, MTLPixelFormatBGRA8Unorm_sRGB) != 0;
    failed += tex_need_pfv(MTLPixelFormatBC7_RGBAUnorm, MTLPixelFormatBC7_RGBAUnorm_sRGB) != 0;
    failed += tex_need_pfv(MTLPixelFormatRGBA8Unorm, MTLPixelFormatR32Uint) != 1;
    tex_t t = {.magic=MAGIC('T', 'E', 'X', 0), .serial = 70001};
    t.d.width = 4; t.d.height = 1; t.d.depth = 1; t.d.levels = 1; t.d.target = NVN_TEXTURE_TARGET_2D; t.d.format = NVN_FORMAT_RGBA8;
    mtl_init();
    MTLTextureDescriptor *d = tex_desc(&t, 0);
    failed += (d.usage & MTLTextureUsagePixelFormatView) != 0;
    id<MTLTexture> base = [g_dev newTextureWithDescriptor:d];
    uint8_t bytes[16] = {1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16};
    id<MTLBuffer> src = [g_dev newBufferWithBytes:bytes length:sizeof bytes options:MTLResourceStorageModeShared];
    mtl_sub_begin();
    res_add(src); res_add(base);   // Metal 4: both ends of a copy must be in the residency set
    id fill = blit();   // copies on the main command buffer go through the host wrapper (which carries its own barrier)
    [fill copyFromBuffer:src sourceOffset:0 sourceBytesPerRow:16 sourceBytesPerImage:16 sourceSize:MTLSizeMake(4, 1, 1)
               toTexture:base destinationSlice:0 destinationLevel:0 destinationOrigin:MTLOriginMake(0, 0, 0)];
    enc_b_end(g_blit); g_blit = nil;
    serial_put(t.serial, base);
    id<MTLTexture> upgraded = tex_upgrade_pfv(&t, base, MTLPixelFormatR32Uint);
    failed += upgraded.pixelFormat != MTLPixelFormatRGBA8Unorm;   // the upgrade keeps the original format
    failed += !(upgraded.usage & MTLTextureUsagePixelFormatView);
    failed += serial_get(t.serial) != upgraded;   // the registration has been replaced
    if (g_blit) { enc_b_end(g_blit); g_blit = nil; }
    id<MTLTexture> view = [upgraded newTextureViewWithPixelFormat:MTLPixelFormatR32Uint];
    id<MTLBuffer> dst = [g_dev newBufferWithLength:sizeof bytes options:MTLResourceStorageModeShared];
    res_add(dst);
    id read = blit();
    [read copyFromTexture:view sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0) sourceSize:MTLSizeMake(4, 1, 1)
                 toBuffer:dst destinationOffset:0 destinationBytesPerRow:16 destinationBytesPerImage:16];
    enc_b_end(g_blit); g_blit = nil;
    mtl_sub_commit(); mtl_drain();
    failed += memcmp(dst.contents, bytes, sizeof bytes) != 0;
    failed += rt_view_class_change();
    printf("pfv predicate failed=%d\n", failed);
    return failed != 0;
}
