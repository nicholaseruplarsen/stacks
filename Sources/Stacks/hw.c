#include "hw.h"

#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>
#include <mach/mach_time.h>
#include <string.h>

// MARK: - SMC

typedef struct { char major, minor, build, reserved; uint16_t release; } smc_vers_t;
typedef struct { uint16_t version, length; uint32_t cpu, gpu, mem; } smc_plimit_t;
typedef struct { uint32_t size; uint32_t type; char attributes; } smc_keyinfo_t;
typedef struct {
    uint32_t key;
    smc_vers_t vers;
    smc_plimit_t plimit;
    smc_keyinfo_t info;
    char result, status, data8;
    uint32_t data32;
    unsigned char bytes[32];
} smc_data_t;

static io_connect_t smc_conn;

#define SMC_CACHE 64
static struct { uint32_t key; smc_keyinfo_t info; bool ok; } smc_cache[SMC_CACHE];
static int smc_cache_n;

static uint32_t fourcc(const char *s) {
    return ((uint32_t)s[0] << 24) | ((uint32_t)s[1] << 16) | ((uint32_t)s[2] << 8) | (uint32_t)s[3];
}

static bool smc_call(smc_data_t *in, smc_data_t *out) {
    size_t outsz = sizeof(smc_data_t);
    memset(out, 0, sizeof(*out));
    return IOConnectCallStructMethod(smc_conn, 2, in, sizeof(*in), out, &outsz) == kIOReturnSuccess && out->result == 0;
}

bool smc_open(void) {
    if (smc_conn) return true;
    io_service_t svc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"));
    if (!svc) return false;
    kern_return_t kr = IOServiceOpen(svc, mach_task_self(), 0, &smc_conn);
    IOObjectRelease(svc);
    return kr == KERN_SUCCESS;
}

static bool smc_info(uint32_t key, smc_keyinfo_t *info) {
    for (int i = 0; i < smc_cache_n; i++)
        if (smc_cache[i].key == key) { *info = smc_cache[i].info; return smc_cache[i].ok; }
    smc_data_t in = {0}, out;
    in.key = key;
    in.data8 = 9;
    bool ok = smc_call(&in, &out);
    if (ok) *info = out.info;
    if (smc_cache_n < SMC_CACHE) {
        smc_cache[smc_cache_n].key = key;
        smc_cache[smc_cache_n].info = out.info;
        smc_cache[smc_cache_n].ok = ok;
        smc_cache_n++;
    }
    return ok;
}

bool smc_read(const char *k, double *out) {
    if (!smc_conn || strlen(k) != 4) return false;
    uint32_t key = fourcc(k);
    smc_keyinfo_t info;
    if (!smc_info(key, &info)) return false;
    smc_data_t in = {0}, res;
    in.key = key;
    in.info.size = info.size;
    in.data8 = 5;
    if (!smc_call(&in, &res)) return false;

    const unsigned char *b = res.bytes;
    uint32_t t = info.type;
    if (t == fourcc("flt ") && info.size == 4) {
        float f;
        memcpy(&f, b, 4);
        *out = f;
    } else if (t == fourcc("sp78")) {
        *out = (int16_t)((b[0] << 8) | b[1]) / 256.0;
    } else if (t == fourcc("fpe2")) {
        *out = ((b[0] << 8) | b[1]) / 4.0;
    } else if (t == fourcc("ui8 ")) {
        *out = b[0];
    } else if (t == fourcc("ui16")) {
        *out = (b[0] << 8) | b[1];
    } else if (t == fourcc("ui32")) {
        *out = ((uint32_t)b[0] << 24) | ((uint32_t)b[1] << 16) | ((uint32_t)b[2] << 8) | b[3];
    } else if (t == fourcc("ioft") && info.size == 8) {
        uint64_t v;
        memcpy(&v, b, 8);
        *out = v / 65536.0;
    } else {
        return false;
    }
    return true;
}

// MARK: - IOReport (private, linked through the SDK's libIOReport.tbd)

typedef struct IOReportSubscription *IOReportSubscriptionRef;
extern CFDictionaryRef IOReportCopyChannelsInGroup(CFStringRef, CFStringRef, uint64_t, uint64_t, uint64_t);
extern void IOReportMergeChannels(CFDictionaryRef, CFDictionaryRef, CFTypeRef);
extern IOReportSubscriptionRef IOReportCreateSubscription(void *, CFMutableDictionaryRef, CFMutableDictionaryRef *, uint64_t, CFTypeRef);
extern CFDictionaryRef IOReportCreateSamples(IOReportSubscriptionRef, CFMutableDictionaryRef, CFTypeRef);
extern CFDictionaryRef IOReportCreateSamplesDelta(CFDictionaryRef, CFDictionaryRef, CFTypeRef);
extern CFStringRef IOReportChannelGetGroup(CFDictionaryRef);
extern CFStringRef IOReportChannelGetSubGroup(CFDictionaryRef);
extern CFStringRef IOReportChannelGetChannelName(CFDictionaryRef);
extern CFStringRef IOReportChannelGetUnitLabel(CFDictionaryRef);
extern int64_t IOReportSimpleGetIntegerValue(CFDictionaryRef, int32_t);
extern int32_t IOReportStateGetCount(CFDictionaryRef);
extern CFStringRef IOReportStateGetNameForIndex(CFDictionaryRef, int32_t);
extern int64_t IOReportStateGetResidency(CFDictionaryRef, int32_t);

static IOReportSubscriptionRef ior_sub;
static CFMutableDictionaryRef ior_subbed;
static CFDictionaryRef ior_prev;
static uint64_t ior_prev_time;

#define MAXF 32
static double freq_e[MAXF], freq_p[MAXF], freq_g[MAXF];
static int nfreq_e, nfreq_p, nfreq_g;

static int read_freqs(io_registry_entry_t e, const char *prop, double *dst) {
    CFStringRef key = CFStringCreateWithCString(NULL, prop, kCFStringEncodingUTF8);
    CFDataRef data = IORegistryEntryCreateCFProperty(e, key, kCFAllocatorDefault, 0);
    CFRelease(key);
    if (!data) return 0;
    int n = 0;
    CFIndex len = CFDataGetLength(data);
    const uint8_t *p = CFDataGetBytePtr(data);
    for (CFIndex i = 0; i + 8 <= len && n < MAXF; i += 8) {
        uint32_t f;
        memcpy(&f, p + i, 4);
        if (f == 0) continue;
        // Tables are in Hz on M1-M3 and kHz on M4+.
        dst[n++] = f > 100000000 ? f / 1e6 : f / 1e3;
    }
    CFRelease(data);
    return n;
}

static void load_freq_tables(void) {
    io_iterator_t it;
    if (IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("AppleARMIODevice"), &it) != KERN_SUCCESS) return;
    io_registry_entry_t e;
    while ((e = IOIteratorNext(it))) {
        io_name_t name;
        if (IORegistryEntryGetName(e, name) == KERN_SUCCESS && strcmp(name, "pmgr") == 0) {
            nfreq_e = read_freqs(e, "voltage-states1-sram", freq_e);
            nfreq_p = read_freqs(e, "voltage-states5-sram", freq_p);
            nfreq_g = read_freqs(e, "voltage-states9", freq_g);
        }
        IOObjectRelease(e);
    }
    IOObjectRelease(it);
}

static void merge(CFMutableDictionaryRef into, const char *group, const char *sub) {
    CFStringRef g = CFStringCreateWithCString(NULL, group, kCFStringEncodingUTF8);
    CFStringRef s = sub ? CFStringCreateWithCString(NULL, sub, kCFStringEncodingUTF8) : NULL;
    CFDictionaryRef ch = IOReportCopyChannelsInGroup(g, s, 0, 0, 0);
    if (ch) {
        IOReportMergeChannels(into, ch, NULL);
        CFRelease(ch);
    }
    CFRelease(g);
    if (s) CFRelease(s);
}

bool ior_open(void) {
    if (ior_sub) return true;
    load_freq_tables();
    CFStringRef g = CFSTR("Energy Model");
    CFDictionaryRef energy = IOReportCopyChannelsInGroup(g, NULL, 0, 0, 0);
    if (!energy) return false;
    CFMutableDictionaryRef chans = CFDictionaryCreateMutableCopy(NULL, CFDictionaryGetCount(energy), energy);
    CFRelease(energy);
    merge(chans, "CPU Stats", "CPU Complex Performance States");
    merge(chans, "GPU Stats", "GPU Performance States");
    ior_sub = IOReportCreateSubscription(NULL, chans, &ior_subbed, 0, NULL);
    CFRelease(chans);
    return ior_sub != NULL;
}

static bool str_eq(CFStringRef s, const char *c) {
    char buf[128];
    return s && CFStringGetCString(s, buf, sizeof buf, kCFStringEncodingUTF8) && strcmp(buf, c) == 0;
}

static bool str_has_prefix(CFStringRef s, const char *c) {
    char buf[128];
    return s && CFStringGetCString(s, buf, sizeof buf, kCFStringEncodingUTF8) && strncmp(buf, c, strlen(c)) == 0;
}

static double to_joules(CFDictionaryRef ch, int64_t v) {
    CFStringRef unit = IOReportChannelGetUnitLabel(ch);
    if (str_eq(unit, "mJ")) return v / 1e3;
    if (str_eq(unit, "uJ")) return v / 1e6;
    if (str_eq(unit, "nJ")) return v / 1e9;
    return 0;
}

/// Residency-weighted frequency over active states, mapped onto the pmgr table.
static void residency(CFDictionaryRef ch, const double *table, int ntable, double *mhz, double *active) {
    int32_t n = IOReportStateGetCount(ch);
    double total = 0, busy = 0, weighted = 0;
    int idx = 0;
    for (int32_t i = 0; i < n; i++) {
        int64_t r = IOReportStateGetResidency(ch, i);
        CFStringRef name = IOReportStateGetNameForIndex(ch, i);
        total += r;
        if (str_eq(name, "IDLE") || str_eq(name, "OFF") || str_eq(name, "DOWN")) continue;
        if (idx < ntable) weighted += r * table[idx];
        busy += r;
        idx++;
    }
    *mhz = busy > 0 ? weighted / busy : 0;
    *active = total > 0 ? busy / total : 0;
}

bool ior_sample(ior_sample_t *out) {
    if (!ior_sub) return false;
    CFDictionaryRef cur = IOReportCreateSamples(ior_sub, ior_subbed, NULL);
    if (!cur) return false;
    uint64_t now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
    CFDictionaryRef prev = ior_prev;
    uint64_t prev_time = ior_prev_time;
    ior_prev = cur;
    ior_prev_time = now;
    if (!prev) return false;

    CFDictionaryRef delta = IOReportCreateSamplesDelta(prev, cur, NULL);
    CFRelease(prev);
    if (!delta) return false;

    memset(out, 0, sizeof(*out));
    out->seconds = (now - prev_time) / 1e9;
    CFArrayRef items = CFDictionaryGetValue(delta, CFSTR("IOReportChannels"));
    CFIndex n = items ? CFArrayGetCount(items) : 0;
    for (CFIndex i = 0; i < n; i++) {
        CFDictionaryRef ch = CFArrayGetValueAtIndex(items, i);
        CFStringRef group = IOReportChannelGetGroup(ch);
        CFStringRef name = IOReportChannelGetChannelName(ch);
        if (str_eq(group, "Energy Model")) {
            double j = to_joules(ch, IOReportSimpleGetIntegerValue(ch, 0));
            if (str_eq(name, "CPU Energy")) out->cpu_j += j;
            else if (str_eq(name, "GPU Energy")) out->gpu_j += j;
            else if (str_has_prefix(name, "ANE")) out->ane_j += j;
            else if (str_has_prefix(name, "DRAM")) out->dram_j += j;
        } else if (str_eq(group, "CPU Stats")) {
            if (str_eq(name, "ECPU")) residency(ch, freq_e, nfreq_e, &out->ecpu_mhz, &out->ecpu_active);
            else if (str_eq(name, "PCPU")) residency(ch, freq_p, nfreq_p, &out->pcpu_mhz, &out->pcpu_active);
        } else if (str_eq(group, "GPU Stats")) {
            if (str_eq(name, "GPUPH")) residency(ch, freq_g, nfreq_g, &out->gpu_mhz, &out->gpu_active);
        }
    }
    CFRelease(delta);
    return true;
}
