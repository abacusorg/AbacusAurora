// nodeprep: make a node's free memory whole again from user space, before a run.
//
// A free block smaller than 2 MiB exists only while another page in its 2 MiB block is in use.
// Compaction can only migrate such pages, and Lustre's page cache never migrates (the client's
// migrate_folio returns -EIO); reclaim drops clean page cache outright.  A process can trigger
// reclaim on a NUMA node only by allocating there until the node's free memory reaches its low
// watermark.  So for each node with CPUs, --reclaim fills free memory -- with huge pages while
// free 2 MiB blocks last, then with 4 KiB pages, which take the small blocks and then force
// reclaim -- until the node's file LRU is nearly empty or reclaim stops making progress, then
// frees it all.  Pages freed by reclaim merge with their free neighbours.  Unreclaimable kernel
// memory and other processes' anonymous or pinned pages stay where they are.
//
// --reclaim raises oom_score_adj to 1000 first, so an overshoot kills this process and nothing
// else, and it refuses to run outside a PBS job.  Without it, nodeprep only reports.
//
// Usage: nodeprep [--reclaim] [--threads N] [--keep-file-mib M] [--max-seconds S]
// Prints one line per node per phase, prefixed with the host name.  Sizes are GiB.
// hashrun.sh builds it and multisim.pbs runs it on every node, both through job/nodeprep.sh.
#include <pthread.h>
#include <sched.h>
#include <sys/mman.h>
#include <sys/syscall.h>
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
    double free = 0, free_2m = 0, file = 0, sreclaimable = 0, kreclaimable = 0, low = 0;
};

NodeMem read_node(int node) {
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
    });
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
        if (cur == node && sscanf(line.c_str(), " %31s %lf", word, &v) == 2 && !strcmp(word, "low"))
            m.low += v * kPage;
    });
    return m;
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

std::string describe(const NodeMem &m) {
    char b[256];
    snprintf(b, sizeof b,
             "free %.1f, in >= 2 MiB blocks %.1f, smaller %.1f; file LRU %.1f, SReclaimable %.1f, "
             "KReclaimable %.1f",
             m.free / kGiB, m.free_2m / kGiB, (m.free - m.free_2m) / kGiB, m.file / kGiB,
             m.sreclaimable / kGiB, m.kreclaimable / kGiB);
    return b;
}

struct Result {
    int node = -1;
    NodeMem before, deepest, after;
    size_t huge = 0, small = 0;
    double t_huge = 0, t_small = 0, t_free = 0;
    const char *stop_huge = "", *stop_small = "";
    int err_huge = 0, err_small = 0;
};

void reclaim_node(Result &res, int nthreads, double keep_file, double max_s) {
    const int node = res.node;
    const std::vector<int> cpus = node_cpus(node);
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
        res.stop_huge = mon.reason;
    }
    res.t_huge = now_s() - t0;

    // 4 KiB pages: they take the small free blocks first, then drive the node into reclaim.
    const NodeMem mid = read_node(node);
    Region small = map_bound((size_t) (mid.free + mid.file + mid.sreclaimable), node, MADV_NOHUGEPAGE);
    t0 = now_s();
    {
        std::atomic<bool> stop{false};
        double last_t = 0, last_file = mid.file;
        Monitor mon(stop, node, [&](const NodeMem &m, double t) -> const char * {
            if (m.file <= keep_file) return "file LRU drained";
            if (t > max_s) return "time limit";
            // At the watermark with the file LRU no longer shrinking: what is left is not reclaimable.
            if (t - last_t >= 0.5) {
                const bool stalled = m.free <= m.low + 512.0 * kMiB && last_file - m.file < 64.0 * kMiB;
                last_t = t;
                last_file = m.file;
                if (stalled) return "reclaim stalled";
            }
            return nullptr;
        });
        res.small = small.p ? fill(small.p, small.len, 32 * kMiB, nthreads, cpus, stop, res.err_small) : 0;
        res.stop_small = mon.reason;
    }
    res.t_small = now_s() - t0;
    res.deepest = read_node(node);

    t0 = now_s();
    release(small, nthreads, cpus);
    release(huge, nthreads, cpus);
    res.t_free = now_s() - t0;
    res.after = read_node(node);
}

}  // namespace

int main(int argc, char **argv) {
    bool reclaim = false;
    int nthreads = 16;
    double keep_file = 1024.0 * kMiB, max_s = 120;
    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--reclaim")) reclaim = true;
        else if (!strcmp(argv[i], "--threads") && i + 1 < argc) nthreads = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--keep-file-mib") && i + 1 < argc) keep_file = atof(argv[++i]) * kMiB;
        else if (!strcmp(argv[i], "--max-seconds") && i + 1 < argc) max_s = atof(argv[++i]);
        else {
            fprintf(stderr, "usage: %s [--reclaim] [--threads N] [--keep-file-mib M] [--max-seconds S]\n", argv[0]);
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
            printf("%s node %d%s: %s; low watermark %.2f\n", host, n, node_cpus(n).empty() ? " (no cpus)" : "",
                   describe(m).c_str(), m.low / kGiB);
        }
        return 0;
    }
    if (!getenv("PBS_JOBID")) {
        fprintf(stderr, "%s: --reclaim fills every node's memory; refusing to run outside a PBS job\n", argv[0]);
        return 2;
    }
    if (FILE *f = fopen("/proc/self/oom_score_adj", "w")) {
        fputs("1000", f);
        fclose(f);
    }

    std::vector<Result> res;
    for (int n : nodes)
        if (!node_cpus(n).empty()) {
            res.emplace_back();
            res.back().node = n;
        }
    std::vector<std::thread> workers;
    for (auto &r : res) workers.emplace_back([&r, nthreads, keep_file, max_s] {
        reclaim_node(r, nthreads, keep_file, max_s);
    });
    for (auto &w : workers) w.join();

    for (const auto &r : res) {
        printf("%s node %d before:  %s\n", host, r.node, describe(r.before).c_str());
        printf("%s node %d filled:  %.1f huge in %.1f s (%s%s%s), %.1f small in %.1f s (%s%s%s)\n", host,
               r.node, r.huge / kGiB, r.t_huge, r.stop_huge, r.err_huge ? " errno " : "",
               r.err_huge ? strerror(r.err_huge) : "", r.small / kGiB, r.t_small, r.stop_small,
               r.err_small ? " errno " : "", r.err_small ? strerror(r.err_small) : "");
        printf("%s node %d deepest: %s; low watermark %.2f\n", host, r.node, describe(r.deepest).c_str(),
               r.deepest.low / kGiB);
        printf("%s node %d after:   %s; freed in %.1f s\n", host, r.node, describe(r.after).c_str(), r.t_free);
    }
    return 0;
}
