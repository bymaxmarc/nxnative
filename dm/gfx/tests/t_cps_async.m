// A compute shader Apple's compiler takes minutes (or forever) to build (Nintendo Switch Sports Resort), stood in for by an MTLDevice whose build of the kernel named "hold_k"
// waits until the test releases it. Its pipeline is built off the submit thread (cps_get in nvn_mtl.m): its first dispatch waits a bounded time and is skipped, later work of the
// same submission runs, later dispatches of it are skipped without waiting or building it again, and once the build returns its dispatches run. A pipeline the archive holds is
// taken at once on the submit thread, with no build. The held build is named in the log as slow, and its pipeline is captured into a flush period of its own (arch_harvest_solo),
// so it holds back no other pipeline's file
#include "../nvn/nvn_mtl.m"
#include <objc/runtime.h>
void *front_metal_layer(void) { return NULL; }
module_t *module_of(const void *p) { (void)p; return NULL; }
module_t *g_mod; int g_nmod;
void svc_thread_dump(void) {}
uint64_t now_ns(void) { return bp_now(); }
static int checks, failed;
#define CHECK(c, label) do { checks++; if (!(c)) { failed++; fprintf(stderr, "FAIL: %s\n", label); } } while (0)

// The MTLDevice's compute pipeline build, counted by kernel name and held for "hold_k" until released
typedef id (*cps_fn)(id, SEL, id, NSError **);
static cps_fn g_real_cps; static dispatch_semaphore_t g_entered, g_release;
static _Atomic int g_builds_hold, g_builds_free, g_builds_arch, g_builds_on_submit;
static pthread_t g_submit;
static id fake_cps(id self, SEL cmd, id<MTLFunction> f, NSError **e) {
    if (pthread_equal(pthread_self(), g_submit)) g_builds_on_submit++;
    if ([f.name isEqualToString:@"hold_k"]) { g_builds_hold++; dispatch_semaphore_signal(g_entered); dispatch_semaphore_wait(g_release, DISPATCH_TIME_FOREVER); }
    else if ([f.name isEqualToString:@"free_k"]) g_builds_free++;
    else if ([f.name isEqualToString:@"arch_k"]) g_builds_arch++;
    return g_real_cps(self, cmd, f, e);
}
static int until(int (^cond)(void), double seconds) { uint64_t t0 = bp_now(); while (!cond()) { if (bp_now() - t0 > seconds * 1e9) return 0; usleep(10000); } return 1; }

// A program whose compute shader is kernel name of lib: it writes its value to out[thread]
static prog_t *program(uint64_t serial, id<MTLLibrary> lib, NSString *name) {
    prog_t *pg = calloc(1, sizeof *pg); pg->serial = serial;
    NvProg *p = [NvProg new]; NvShader *cs = [NvShader new];
    p->sh[5] = cs; cs->stage = 5; cs->fn = fn4_note([lib newFunctionWithName:name], lib, name, nil);
    strlcpy(cs->key, [name stringByAppendingString:@"_b"].UTF8String, sizeof cs->key);
    cs->ae = [cs->fn newArgumentEncoderWithBufferIndex:0];
    cs->rf.tg[0] = cs->rf.tg[1] = cs->rf.tg[2] = 1;
    cs->rf.nb = 1; cs->rf.b[0] = (nvn_rbind){.kind=NVN_RB_SBUFP, .rw=1, .reg=0, .aid=0};
    serial_put(serial, p);
    return pg;
}
static uint32_t *g_mem;
enum { OUT_WORDS = 64, THREADS = 4 };
// One submission: each program dispatched in turn, program i writing out[i * OUT_WORDS ...]; ms: how long the replay took, without the GPU's time
static double submit(prog_t **pgs, int n) {
    memset(g_mem, 0, 4096);
    mtl_sub_begin(); state_reset(); memset(&R, 0, sizeof R);
    uint64_t t0 = bp_now();
    for (int i = 0; i < n; i++) {
        S.cprog = pgs[i]; S.ssbo[5][0] = (p_bind_buf){.addr=(uint64_t)(g_mem + i * OUT_WORDS), .size=OUT_WORDS * 4};
        p_dispatch dp = {.x=THREADS, .y=1, .z=1}; dispatch(&dp);
    }
    double ms = (bp_now() - t0) / 1e6;
    uint64_t fence = mtl_sub_commit(); if (!mtl_wait(fence, 5000000000ull)) { fprintf(stderr, "FAIL: GPU timeout\n"); failed++; }
    mtl_drain();
    return ms;
}
static int wrote(int i, uint32_t v) { for (int t = 0; t < THREADS; t++) if (g_mem[i * OUT_WORDS + t] != v) return 0; return 1; }

int main(void) { @autoreleasepool {
    char tmp[] = "/tmp/t_cps_async.XXXXXX"; if (!mkdtemp(tmp)) abort();
    NSString *arch = [@(tmp) stringByAppendingPathComponent:@"archive"];
    setenv("DM_PSO_ARCHIVE", arch.UTF8String, 1); setenv("DM_PSO_MANIFEST", "off", 1);
    mtl_init(); pso4_init();
    if (!g_comp4 || !g_arch_cap) { printf("t_cps_async: no Metal 4 compiler, not run\n"); return 0; }
    g_submit = pthread_self();
    g_entered = dispatch_semaphore_create(0); g_release = dispatch_semaphore_create(0);
    Method m = class_getInstanceMethod(object_getClass((id)g_dev), @selector(newComputePipelineStateWithFunction:error:));
    if (!m) abort();
    g_real_cps = (cps_fn)method_setImplementation(m, (IMP)fake_cps);
    g_cps_wait_ms = 300; g_slow_ms = 200;   // the bound on a first dispatch's wait, and when a compile is named as slow (5 s each in a run)

    NSError *error = nil;
    NSString *src = @"#include <metal_stdlib>\nusing namespace metal;\nstruct Args { device uint *out [[id(0)]]; };\n"
        "kernel void hold_k(constant Args &a [[buffer(0)]], uint3 p [[thread_position_in_grid]]) { a.out[p.x] = 7; }\n"
        "kernel void free_k(constant Args &a [[buffer(0)]], uint3 p [[thread_position_in_grid]]) { a.out[p.x] = 9; }\n"
        "kernel void arch_k(constant Args &a [[buffer(0)]], uint3 p [[thread_position_in_grid]]) { a.out[p.x] = 5; }\n";
    id<MTLLibrary> lib = [g_dev newLibraryWithSource:[src stringByAppendingFormat:@"// %d\n", getpid()] options:nil error:&error];
    CHECK(lib != nil, "synthetic compute shaders compile"); if (!lib) return 1;
    if (posix_memalign((void **)&g_mem, getpagesize(), getpagesize())) return 1;
    mtl_pool_add(g_mem, getpagesize());
    prog_t *hold = program(970001, lib, @"hold_k"), *fre = program(970002, lib, @"free_k");

    // held: the replay goes on. The first dispatch waits at most the bound and is skipped; the next program's dispatch runs in the same submission; a second dispatch of the held
    // shader neither waits nor asks for another build
    uint64_t async0 = g_cps_async, skipped0 = g_cps_skipped, told0 = g_slow_told;
    double ms = submit((prog_t *[]){hold, fre, hold}, 3);
    CHECK(!dispatch_semaphore_wait(g_entered, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC)), "held: its build started");
    CHECK(ms < 300 + 150 + 2000, "held: the replay waited about the bound, not for the build");
    CHECK(ms >= 250, "held: the first dispatch waited for the bound");
    CHECK(wrote(0, 0) && wrote(2, 0), "held: its dispatches skipped");
    CHECK(wrote(1, 9), "held: a later dispatch in the submission ran");
    CHECK(g_builds_hold == 1, "held: built once");
    CHECK(g_builds_on_submit == 0, "held: no build on the submit thread");
    CHECK(g_cps_async - async0 == 2, "held: both pipelines built in the background");
    CHECK(g_cps_skipped - skipped0 == 2, "held: two dispatches counted as skipped");
    ms = submit((prog_t *[]){fre, hold}, 2);
    CHECK(ms < 250, "held, next submission: no wait for the held build (the bound is 300 ms)");
    CHECK(wrote(0, 9) && wrote(1, 0), "held, next submission: the other runs, the held one is skipped");
    CHECK(g_builds_hold == 1 && g_builds_free == 1, "held, next submission: nothing built again");
    CHECK(until(^{ return (int)(g_slow_told > told0); }, 5), "held: named in the log as still compiling");

    // released: the next dispatch takes the pipeline, built once; the build is captured into a period of its own and written, the current period untouched
    dispatch_sync(arch_harvest_q(), ^{});   // the other pipeline's capture, into the current period
    uint64_t solo0 = g_arch_solo; int cur_n = atomic_load(&g_ep->n);
    dispatch_semaphore_signal(g_release);
    CHECK(until(^{ return (int)(g_arch_solo > solo0); }, 30), "released: its pipeline captured alone and written");
    CHECK(atomic_load(&g_ep->n) == cur_n, "released: the current flush period holds nothing of it");
    submit((prog_t *[]){hold}, 1);
    CHECK(wrote(0, 7), "released: its dispatch runs");
    CHECK(g_builds_hold == 1, "released: not built again");
    CHECK(g_builds_on_submit == 0, "released: no build on the submit thread");

    // the cached path: a pipeline in the archive is taken on the submit thread, at once, with no build
    id<MTLFunction> af = fn4_note([lib newFunctionWithName:@"arch_k"], lib, @"arch_k", nil);
    CHECK(cps_new(af, &error) != nil, "archived: built once for the archive");
    dispatch_sync(arch_harvest_q(), ^{});
    arch_flush_wait();
    NSMutableArray<id<MTL4Archive>> *open = [NSMutableArray array];
    for (NSString *n in [NSFileManager.defaultManager contentsOfDirectoryAtPath:arch error:nil]) if ([n hasSuffix:@".mtl4a"]) {
        id<MTL4Archive> a = [g_dev newArchiveWithURL:[NSURL fileURLWithPath:[arch stringByAppendingPathComponent:n]] error:nil];
        if (a) [open addObject:a];
    }
    CHECK(open.count >= 2, "archived: the files written");
    g_arch4 = open;   // as a new start with those files (the index is empty: every file is asked)
    int builds = g_builds_arch; uint64_t run0 = g_cps_run, async1 = g_cps_async;
    prog_t *ap = program(970003, lib, @"arch_k");
    submit((prog_t *[]){ap}, 1);
    CHECK(wrote(0, 5), "archived: its first dispatch runs");
    CHECK(g_builds_arch == builds, "archived: not built");
    CHECK(g_cps_run == run0 + 1, "archived: taken from the archive");
    CHECK(g_cps_async == async1, "archived: nothing built in the background");
    // the held shader's pipeline is in its own file too: a new shader with its function takes it from there
    int hb = g_builds_hold; prog_t *hp = program(970004, lib, @"hold_k");
    submit((prog_t *[]){hp}, 1);
    CHECK(wrote(0, 7) && g_builds_hold == hb, "archived: the held shader's pipeline taken from its own file");

    method_setImplementation(m, (IMP)g_real_cps);
    [NSFileManager.defaultManager removeItemAtPath:@(tmp) error:nil];
    printf("t_cps_async: %d checks, %d failed\n", checks, failed);
    return failed != 0;
} }
