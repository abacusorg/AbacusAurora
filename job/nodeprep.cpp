// nodeprep: make a node's free memory whole again from user space, before a run.
//
// A free block smaller than 2 MiB exists only while another page in its 2 MiB block is in use.
// Compaction can only migrate such pages, and Lustre's page cache never migrates (the client's
// migrate_folio returns -EIO); reclaim drops clean page cache outright.  A process can trigger
// reclaim on a NUMA node only by allocating there until the node's free memory reaches its low
// watermark.  So for each node, --reclaim fills free memory -- with huge pages while
// free 2 MiB blocks last, then with 4 KiB pages, which take the small blocks and then force
// reclaim -- until the node's file LRU is nearly empty or reclaim stops making progress, then
// frees it all.  Pages freed by reclaim merge with their free neighbours.  Unreclaimable kernel
// memory and other processes' anonymous or pinned pages stay where they are.
//
// On a node with CPUs the 4 KiB fill runs at full speed: its page cache is large, and reclaim
// keeps up until the file LRU is nearly empty.  Where little is reclaimable, a fill that outruns
// reclaim is killed at once, so the careful fill (squeeze()) takes half of the room above a floor
// at a time -- the midpoint of the zone's min and low watermarks -- and at the floor takes
// huge-page faults under MADV_HUGEPAGE.  With no free 2 MiB block left, such a fault reclaims on
// its own thread, kernel caches included, and settles for a 4 KiB page if that frees nothing.
// A 4 KiB fault would wait on kswapd, which stops answering for a node it has failed on.
// When such a fault does get a 2 MiB block, the fill frees every other page of 4 MiB of its own
// 4 KiB pages in exchange, so the memory left free turns into fragments.
// A memory-only node (HBM), which has only its page cache, is filled that way.  So is a node with
// CPUs that ends its pass with less than --need-gib in whole 2 MiB blocks, on a second pass: it
// shrinks the kernel's reclaimable caches (KReclaimable), which can hold a socket's free memory
// in fragments, and which the first pass leaves once the file LRU is drained.
//
// Each node's pass is a child process with oom_score_adj 1000: an overshoot kills that pass and
// nothing else, and the parent reports the node as the kernel left it.  Nodes with CPUs go first;
// the memory-only nodes' page tables come from them.  --reclaim refuses to run outside a PBS job.
// Without it, nodeprep only reports.
//
// Usage: nodeprep [--reclaim] [--threads N] [--keep-file-mib M] [--need-gib G] [--max-seconds S]
// Prints one line per node per phase, prefixed with the host name; a memory-only node's lines say
// "memnode".  Sizes are GiB.  --keep-file-mib and --need-gib apply to nodes with CPUs.
// hashrun.sh builds it and multisim.pbs runs it on every node, both through job/nodeprep.sh.
#include <pthread.h>
#include <sched.h>
#include <sys/mman.h>
#include <sys/syscall.h>
#include <sys/wait.h>
#include <unistd.h>

#include <algorithm>
#include <atomic>
#include <cerrno>
#include <chrono>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <thread>
#include <vector>

#ifndef MADV_POPULATE_WRITE
#define MADV_POPULATE_WRITE 23
#endif

namespace {

constexpr int kMpolBind = 2;
constexpr size_t kPage = 4096;
constexpr size_t kHuge = 2ul << 20;
constexpr size_t kMiB = 1ul << 20;
constexpr size_t kGiBz = 1ul << 30;
constexpr double kGiB = 1024.0 * 1024 * 1024;

double now_s() {
    return std::chrono::duration<double>(std::chrono::steady_clock::now().time_since_epoch()).count();
}

std::string slurp(const char *path) {
    std::string s;
    FILE *f = fopen(path, "r");
    if (!f) return s;
    char buf[1 << 16];
    size_t n;
    while ((n = fread(buf, 1, sizeof buf, f)) > 0) s.append(buf, n);
    fclose(f);
    return s;
}

template <class F>
void for_each_line(const std::string &s, F f) {
    size_t pos = 0;
    while (pos < s.size()) {
        size_t eol = s.find('\n', pos);
        if (eol == std::string::npos) eol = s.size();
        f(s.substr(pos, eol - pos));
        pos = eol + 1;
    }
}

struct NodeMem {  // bytes
    double free = 0, free_2m = 0, file = 0, sreclaimable = 0, kreclaimable = 0, sunreclaim = 0, shmem = 0, anon = 0,
           min = 0, low = 0;
};

// `counters_only` skips the free-block and watermark fields, which cost over a millisecond to read.
NodeMem read_node(int node, bool counters_only = false) {
    NodeMem m;
    char path[96];
    snprintf(path, sizeof path, "/sys/devices/system/node/node%d/meminfo", node);
    for_each_line(slurp(path), [&](const std::string &line) {
        char key[64];
        double kb;
        if (sscanf(line.c_str(), "Node %*d %63[^:]: %lf", key, &kb) != 2) return;
        if (!strcmp(key, "MemFree")) m.free = kb * 1024;
        else if (!strcmp(key, "Active(file)") || !strcmp(key, "Inactive(file)")) m.file += kb * 1024;
        else if (!strcmp(key, "SReclaimable")) m.sreclaimable = kb * 1024;
        else if (!strcmp(key, "KReclaimable")) m.kreclaimable = kb * 1024;
        else if (!strcmp(key, "SUnreclaim")) m.sunreclaim = kb * 1024;
        else if (!strcmp(key, "Shmem")) m.shmem = kb * 1024;
        else if (!strcmp(key, "AnonPages")) m.anon = kb * 1024;
    });
    if (counters_only) return m;
    for_each_line(slurp("/proc/buddyinfo"), [&](const std::string &line) {
        int n, off = 0;
        char zone[32];
        if (sscanf(line.c_str(), "Node %d, zone %31s%n", &n, zone, &off) != 2 || n != node) return;
        const char *p = line.c_str() + off;
        for (int order = 0;; order++) {
            char *end;
            const unsigned long long c = strtoull(p, &end, 10);
            if (end == p) break;
            if (order >= 9) m.free_2m += (double) c * (double) (kPage << order);
            p = end;
        }
    });
    // Watermark lines read "        low      N" (pages); the per-cpu "high:" lines carry a colon.
    int cur = -1;
    for_each_line(slurp("/proc/zoneinfo"), [&](const std::string &line) {
        int n;
        char zone[32], word[32];
        double v;
        if (sscanf(line.c_str(), "Node %d, zone %31s", &n, zone) == 2) {
            cur = n;
            return;
        }
        if (cur != node || sscanf(line.c_str(), " %31s %lf", word, &v) != 2) return;
        if (!strcmp(word, "min")) m.min += v * kPage;
        else if (!strcmp(word, "low")) m.low += v * kPage;
    });
    return m;
}

struct ZoneMem {  // bytes
    double free = 0, min = 0, low = 0;
};

// The node's largest zone, the one user pages come from: on a DDR node, free memory in the small
// DMA zones is reserved against them and never falls.
ZoneMem read_zone(int node) {
    ZoneMem z, best;
    double managed = -1, best_managed = -1;
    bool mine = false;
    const auto close_zone = [&] {
        if (mine && managed > best_managed) {
            best = z;
            best_managed = managed;
        }
    };
    for_each_line(slurp("/proc/zoneinfo"), [&](const std::string &line) {
        int n;
        char zone[32], word[32];
        double v;
        if (sscanf(line.c_str(), "Node %d, zone %31s", &n, zone) == 2) {
            close_zone();
            mine = n == node;
            z = ZoneMem();
            managed = -1;
        } else if (!mine) {
            return;
        } else if (sscanf(line.c_str(), " pages free %lf", &v) == 1) {
            z.free = v * kPage;
        } else if (sscanf(line.c_str(), " %31s %lf", word, &v) == 2) {
            if (!strcmp(word, "min")) z.min = v * kPage;
            else if (!strcmp(word, "low")) z.low = v * kPage;
            else if (!strcmp(word, "managed")) managed = v;
        }
    });
    close_zone();
    return best;
}

std::vector<int> node_cpus(int node) {
    char path[96];
    snprintf(path, sizeof path, "/sys/devices/system/node/node%d/cpulist", node);
    const std::string s = slurp(path);
    std::vector<int> cpus;
    const char *p = s.c_str();
    while (*p && *p != '\n') {
        char *end;
        const long a = strtol(p, &end, 10);
        if (end == p) break;
        long b = a;
        p = end;
        if (*p == '-') {
            b = strtol(p + 1, &end, 10);
            p = end;
        }
        for (long c = a; c <= b; c++) cpus.push_back((int) c);
        if (*p == ',') p++;
    }
    return cpus;
}

// The node's CPUs, or for a memory-only node those of the nearest node that has any.
std::vector<int> cpus_near(int node) {
    std::vector<int> cpus = node_cpus(node);
    if (!cpus.empty()) return cpus;
    char path[96];
    snprintf(path, sizeof path, "/sys/devices/system/node/node%d/distance", node);
    const std::string s = slurp(path);
    const char *p = s.c_str();
    long best = -1;
    for (int n = 0;; n++) {
        char *end;
        const long d = strtol(p, &end, 10);
        if (end == p) break;
        p = end;
        std::vector<int> c = node_cpus(n);
        if (!c.empty() && (best < 0 || d < best)) {
            best = d;
            cpus = std::move(c);
        }
    }
    return cpus;
}

// An anonymous mapping of `bytes` at a 2 MiB-aligned address, bound to `node`.
struct Region {
    char *base = nullptr, *p = nullptr;
    size_t maplen = 0, len = 0;
};

Region map_bound(size_t bytes, int node, int advice) {
    Region r;
    if (bytes == 0) return r;
    void *v = mmap(nullptr, bytes + kHuge, PROT_READ | PROT_WRITE,
                   MAP_PRIVATE | MAP_ANONYMOUS | MAP_NORESERVE, -1, 0);
    if (v == MAP_FAILED) return r;
    r.base = (char *) v;
    r.maplen = bytes + kHuge;
    r.p = (char *) (((uintptr_t) r.base + kHuge - 1) & ~(uintptr_t) (kHuge - 1));
    r.len = bytes;
    unsigned long mask[4] = {};
    mask[node / 64] |= 1ul << (node % 64);
    if (syscall(SYS_mbind, r.p, r.len, kMpolBind, mask, 4 * 64 + 1, 0) != 0) {
        munmap(r.base, r.maplen);
        return Region{};
    }
    if (advice >= 0) madvise(r.p, r.len, advice);
    return r;
}

void pin(const std::vector<int> &cpus, int t) {
    if (cpus.empty()) return;
    cpu_set_t set;
    CPU_ZERO(&set);
    CPU_SET(cpus[(size_t) t % cpus.size()], &set);
    pthread_setaffinity_np(pthread_self(), sizeof set, &set);
}

// Faults [p, p + len) in `chunk` pieces on `nthreads` threads until done or `stop`.  An in-flight
// chunk always completes, so chunk * nthreads bounds the overshoot past a stop.
size_t fill(char *p, size_t len, size_t chunk, int nthreads, const std::vector<int> &cpus,
            std::atomic<bool> &stop, int &err) {
    std::atomic<size_t> next{0}, done{0};
    std::atomic<int> first_err{0};
    std::vector<std::thread> th;
    for (int t = 0; t < nthreads; t++)
        th.emplace_back([&, t] {
            pin(cpus, t);
            while (!stop.load(std::memory_order_relaxed)) {
                const size_t off = next.fetch_add(chunk);
                if (off >= len) break;
                const size_t n = std::min(chunk, len - off);
                if (madvise(p + off, n, MADV_POPULATE_WRITE) != 0) {
                    int zero = 0;
                    first_err.compare_exchange_strong(zero, errno);
                    stop = true;
                    break;
                }
                done += n;
            }
        });
    for (auto &x : th) x.join();
    err = first_err;
    return done;
}

// The careful fill (see the header) of `r`, with `poke` for the touches at the floor.  Ends once the
// file LRU and kernel caches have not shrunk for 0.5 s, or the touches have used half the floor.
size_t squeeze(const Region &r, const Region &poke, int node, int nthreads, const std::vector<int> &cpus,
               double max_s, const char *&why, int &err) {
    const double t0 = now_s();
    double least = 1e300, progress_t = t0;
    size_t done = 0, poked = 0, punched = 0;
    std::atomic<bool> stop{false};

    // 4 KiB pages to trade for the 2 MiB blocks the touches get: four floors' worth, half of it to free.
    const ZoneMem z0 = read_zone(node);
    Region ballast;
    if (z0.free > 8 * (z0.min + z0.low)) {
        ballast = map_bound(((size_t) (2 * (z0.min + z0.low)) | (2 * kHuge - 1)) + 1, node, MADV_NOHUGEPAGE);
        int ignored = 0;
        if (ballast.p && fill(ballast.p, ballast.len, 32 * kMiB, nthreads, cpus, stop, ignored) != ballast.len) {
            munmap(ballast.base, ballast.maplen);
            ballast = Region{};
        }
    }
    const auto finish = [&](const char *reason) {
        if (reason) why = reason;
        if (ballast.base) munmap(ballast.base, ballast.maplen);
        return done;
    };
    for (;;) {
        const ZoneMem z = read_zone(node);
        const NodeMem m = read_node(node, true);
        const double t = now_s(), floor = (z.min + z.low) / 2, caches = m.file + m.kreclaimable;
        if (caches < least - (double) kMiB) {
            least = caches;
            progress_t = t;
        }
        why = caches < 64.0 * kMiB ? "caches drained" : "reclaim stalled";
        if (t - t0 > max_s) return finish("time limit");
        const size_t step = z.free > floor ? (size_t) ((z.free - floor) / 2) & ~(kHuge - 1) : 0;
        if (step > 0) {
            if (done >= r.len) return finish("region filled");
            const size_t want = std::min(step, r.len - done), got = fill(r.p + done, want, 32 * kMiB, nthreads, cpus, stop, err);
            done += got;
            if (got < want) return finish("fault failed");
            progress_t = now_s();
        } else if (z.free < floor - (double) kMiB && punched + 2 * kHuge <= ballast.len) {
            for (size_t off = kPage; off < 2 * kHuge; off += 2 * kPage)
                madvise(ballast.p + punched + off, kPage, MADV_DONTNEED);
            punched += 2 * kHuge;
            progress_t = t;
        } else if (t - progress_t > 0.5 || poked >= poke.len || caches < (double) kMiB || z.free < (z.min + floor) / 2) {
            return finish(nullptr);
        } else {
            poke.p[poked] = 1;
            poked += kHuge;
        }
    }
}

void release(const Region &r, int nthreads, const std::vector<int> &cpus) {
    if (!r.base) return;
    std::atomic<size_t> next{0};
    std::vector<std::thread> th;
    for (int t = 0; t < nthreads; t++)
        th.emplace_back([&, t] {
            pin(cpus, t);
            for (;;) {
                const size_t off = next.fetch_add(kGiBz);
                if (off >= r.len) break;
                madvise(r.p + off, std::min(kGiBz, r.len - off), MADV_DONTNEED);
            }
        });
    for (auto &x : th) x.join();
    munmap(r.base, r.maplen);
}

// Polls the node every 20 ms on its own thread and sets `stop` with the reason `pred` returns.
struct Monitor {
    std::atomic<bool> &stop;
    std::atomic<bool> quit{false};
    const char *reason = "";
    std::thread th;
    template <class Pred>
    Monitor(std::atomic<bool> &s, int node, Pred pred) : stop(s) {
        th = std::thread([this, node, pred] {
            const double t0 = now_s();
            while (!quit && !stop) {
                if (const char *why = pred(read_node(node), now_s() - t0)) {
                    reason = why;
                    stop = true;
                }
                std::this_thread::sleep_for(std::chrono::milliseconds(20));
            }
        });
    }
    ~Monitor() {
        quit = true;
        th.join();
    }
};

// `ours`: what this process holds on the node, left out of the anonymous memory reported as others'.
std::string describe(const NodeMem &m, double ours = 0) {
    char b[384];
    snprintf(b, sizeof b,
             "free %.1f, in >= 2 MiB blocks %.1f, smaller %.1f; file LRU %.1f, SReclaimable %.1f, "
             "KReclaimable %.1f, SUnreclaim %.1f, Shmem %.1f, others' anon %.1f",
             m.free / kGiB, m.free_2m / kGiB, (m.free - m.free_2m) / kGiB, m.file / kGiB,
             m.sreclaimable / kGiB, m.kreclaimable / kGiB, m.sunreclaim / kGiB, m.shmem / kGiB,
             std::max(0.0, m.anon - ours) / kGiB);
    return b;
}

// Why a fill ended: it faulted its whole region, a fault failed, or the monitor stopped it.
const char *ended(const Region &r, size_t done, int err, const char *monitor) {
    if (!r.p) return "no region";
    if (done == r.len) return "region filled";
    return err ? "fault failed" : monitor;
}

struct Result {
    int node = -1;
    NodeMem before, deepest, after;
    size_t huge = 0, small = 0;
    double t_huge = 0, t_small = 0, t_free = 0;
    const char *stop_huge = "", *stop_small = "";
    int err_huge = 0, err_small = 0;
};

// `press`: the careful fill on a node with CPUs; a memory-only node always gets it.
void reclaim_node(Result &res, int nthreads, double keep_file, bool press, double max_s) {
    const int node = res.node;
    const bool careful = press || node_cpus(node).empty();
    const std::vector<int> cpus = cpus_near(node);
    res.before = read_node(node);

    // Huge pages, stopping short of the free 2 MiB blocks: past them a fault would compact.
    const double slack = std::max(8.0 * kGiB, 0.02 * res.before.free_2m);
    const size_t want = res.before.free_2m > slack
                            ? (size_t) ((res.before.free_2m - slack) / kGiBz) * kGiBz : 0;
    Region huge = map_bound(want, node, -1);
    double t0 = now_s();
    {
        std::atomic<bool> stop{false};
        Monitor mon(stop, node, [&](const NodeMem &m, double t) -> const char * {
            if (m.free_2m < slack / 2) return "2 MiB blocks running out";
            if (t > max_s) return "time limit";
            return nullptr;
        });
        res.huge = huge.p ? fill(huge.p, huge.len, 256 * kMiB, nthreads, cpus, stop, res.err_huge) : 0;
        res.stop_huge = ended(huge, res.huge, res.err_huge, mon.reason);
    }
    res.t_huge = now_s() - t0;

    // 4 KiB pages: they take the small free blocks first, then drive the node into reclaim.  The region
    // holds all that reclaim could free, kernel caches included, so a stop condition ends the fill.
    const NodeMem mid = read_node(node);
    // The careful fill may take huge pages: it then uses up the free 2 MiB blocks, and what it holds
    // back at the floor is all fragments.
    Region small = map_bound((size_t) (mid.free + mid.file + mid.kreclaimable), node, careful ? -1 : MADV_NOHUGEPAGE);
    t0 = now_s();
    if (careful && small.p) {
        const Region poke = map_bound(256 * kGiBz, node, MADV_HUGEPAGE);
        res.small = squeeze(small, poke, node, nthreads, cpus, max_s, res.stop_small, res.err_small);
        if (poke.base) munmap(poke.base, poke.maplen);
    } else {
        std::atomic<bool> stop{false};
        double last_t = 0, last_file = mid.file, last_krec = mid.kreclaimable;
        Monitor mon(stop, node, [&](const NodeMem &m, double t) -> const char * {
            if (m.file <= keep_file) return "file LRU drained";
            if (t > max_s) return "time limit";
            // At the watermark with neither the file LRU nor kernel caches shrinking: the rest is not reclaimable.
            if (t - last_t >= 0.5) {
                const double freed = (last_file - m.file) + (last_krec - m.kreclaimable);
                const bool stalled = m.free <= m.low + 512.0 * kMiB && freed < 64.0 * kMiB;
                last_t = t;
                last_file = m.file;
                last_krec = m.kreclaimable;
                if (stalled) return "reclaim stalled";
            }
            return nullptr;
        });
        res.small = small.p ? fill(small.p, small.len, 32 * kMiB, nthreads, cpus, stop, res.err_small) : 0;
        res.stop_small = ended(small, res.small, res.err_small, mon.reason);
    }
    res.t_small = now_s() - t0;
    res.deepest = read_node(node);

    t0 = now_s();
    release(small, nthreads, cpus);
    release(huge, nthreads, cpus);
    res.t_free = now_s() - t0;
    res.after = read_node(node);
}

// The word a node's lines carry: "memnode" for a node without CPUs.
const char *kind(int node) { return node_cpus(node).empty() ? "memnode" : "node"; }

void print_result(const char *host, const Result &r) {
    const char *k = kind(r.node);
    printf("%s %s %d before:  %s\n", host, k, r.node, describe(r.before).c_str());
    printf("%s %s %d filled:  %.1f huge in %.1f s (%s%s%s), %.1f small in %.1f s (%s%s%s)\n", host, k,
           r.node, r.huge / kGiB, r.t_huge, r.stop_huge, r.err_huge ? " errno " : "",
           r.err_huge ? strerror(r.err_huge) : "", r.small / kGiB, r.t_small, r.stop_small,
           r.err_small ? " errno " : "", r.err_small ? strerror(r.err_small) : "");
    printf("%s %s %d deepest: %s; low watermark %.2f\n", host, k, r.node,
           describe(r.deepest, (double) (r.huge + r.small)).c_str(), r.deepest.low / kGiB);
    printf("%s %s %d after:   %s; freed in %.1f s\n", host, k, r.node, describe(r.after).c_str(), r.t_free);
}

}  // namespace

int main(int argc, char **argv) {
    bool reclaim = false;
    int nthreads = 16;
    double keep_file = 1024.0 * kMiB, need = 0, max_s = 120;
    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--reclaim")) reclaim = true;
        else if (!strcmp(argv[i], "--threads") && i + 1 < argc) nthreads = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--keep-file-mib") && i + 1 < argc) keep_file = atof(argv[++i]) * kMiB;
        else if (!strcmp(argv[i], "--need-gib") && i + 1 < argc) need = atof(argv[++i]) * kGiB;
        else if (!strcmp(argv[i], "--max-seconds") && i + 1 < argc) max_s = atof(argv[++i]);
        else {
            fprintf(stderr, "usage: %s [--reclaim] [--threads N] [--keep-file-mib M] [--need-gib G] [--max-seconds S]\n",
                    argv[0]);
            return 2;
        }
    }
    char host[256] = {};
    gethostname(host, sizeof host - 1);

    std::vector<int> nodes;
    for (int n = 0; n < 256; n++) {
        char path[96];
        snprintf(path, sizeof path, "/sys/devices/system/node/node%d", n);
        if (access(path, F_OK) == 0) nodes.push_back(n);
    }
    if (!reclaim) {
        for (int n : nodes) {
            const NodeMem m = read_node(n);
            printf("%s %s %d: %s; low watermark %.2f\n", host, kind(n), n, describe(m).c_str(), m.low / kGiB);
        }
        return 0;
    }
    if (!getenv("PBS_JOBID")) {
        fprintf(stderr, "%s: --reclaim fills every node's memory; refusing to run outside a PBS job\n", argv[0]);
        return 2;
    }
    struct Pass {
        int node;
        NodeMem before;
        pid_t pid;
    };
    for (const bool with_cpus : {true, false}) {
        std::vector<Pass> passes;
        for (int n : nodes) {
            if (node_cpus(n).empty() == with_cpus) continue;
            const NodeMem before = read_node(n);
            fflush(stdout);
            const pid_t pid = fork();
            if (pid == 0) {
                if (FILE *f = fopen("/proc/self/oom_score_adj", "w")) {
                    fputs("1000", f);
                    fclose(f);
                }
                Result r;
                r.node = n;
                reclaim_node(r, nthreads, keep_file, false, max_s);
                print_result(host, r);
                if (with_cpus && r.after.free_2m < need) {
                    printf("%s %s %d short:   %.1f in >= 2 MiB blocks, %.1f needed; a second pass presses on kernel caches\n",
                           host, kind(n), n, r.after.free_2m / kGiB, need / kGiB);
                    fflush(stdout);
                    r = Result();
                    r.node = n;
                    reclaim_node(r, nthreads, keep_file, true, max_s);
                    print_result(host, r);
                }
                fflush(stdout);
                _exit(0);
            }
            passes.push_back({n, before, pid});
        }
        for (const Pass &p : passes) {
            int status = 0;
            if (p.pid > 0)
                while (waitpid(p.pid, &status, 0) < 0 && errno == EINTR) {}
            if (p.pid > 0 && WIFEXITED(status) && WEXITSTATUS(status) == 0) continue;
            printf("%s %s %d before:  %s\n", host, kind(p.node), p.node, describe(p.before).c_str());
            if (p.pid < 0) printf("%s %s %d failed:  could not fork\n", host, kind(p.node), p.node);
            else if (WIFSIGNALED(status))
                printf("%s %s %d failed:  pass killed by signal %d\n", host, kind(p.node), p.node, WTERMSIG(status));
            else printf("%s %s %d failed:  pass exited with status %d\n", host, kind(p.node), p.node, WEXITSTATUS(status));
            printf("%s %s %d after:   %s\n", host, kind(p.node), p.node, describe(read_node(p.node)).c_str());
        }
    }
    fflush(stdout);
    return 0;
}
