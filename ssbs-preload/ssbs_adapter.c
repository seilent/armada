#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>
#include <sys/auxv.h>
#include <sys/prctl.h>
#include <ucontext.h>
#include <unistd.h>

#define PSTATE_SSBS 0x1000ULL
#define MAX_SIG 65
#define LOG_EVERY 1024UL
#ifndef HWCAP_SSBS
#define HWCAP_SSBS (1UL << 28)
#endif

typedef void (*sigact_fn)(int, siginfo_t *, void *);
typedef void (*sighand_fn)(int);
typedef int (*sigaction_fn)(int, const struct sigaction *, struct sigaction *);

static _Atomic(void *) real_handler[MAX_SIG];
static atomic_int real_siginfo[MAX_SIG];
static atomic_flag init_lock = ATOMIC_FLAG_INIT;
static _Atomic(sigaction_fn) next_sigaction;
static int disabled, observe, nofix;
static const char *log_path = "/tmp/ssbs_adapter.log";
static atomic_ulong n_signals, n_clear;

static void init(void)
{
    if (atomic_load_explicit(&next_sigaction, memory_order_acquire)) return;
    while (atomic_flag_test_and_set_explicit(&init_lock, memory_order_acquire)) {}
    if (!atomic_load_explicit(&next_sigaction, memory_order_relaxed)) {
        const char *e = getenv("SSBS_ADAPTER_DISABLE");
        disabled = e && *e == '1';
        e = getenv("SSBS_ADAPTER_OBSERVE");
        observe = e && *e == '1';
        e = getenv("SSBS_ADAPTER_NOFIX");
        nofix = e && *e == '1';
        e = getenv("SSBS_ADAPTER_LOG");
        if (e && *e) log_path = e;
        atomic_store_explicit(&next_sigaction, (sigaction_fn)dlsym(RTLD_NEXT, "sigaction"), memory_order_release);
    }
    atomic_flag_clear_explicit(&init_lock, memory_order_release);
}

static size_t put_str(char *b, size_t n, const char *s)
{
    while (*s) b[n++] = *s++;
    return n;
}

static size_t put_num(char *b, size_t n, unsigned long v)
{
    char t[24];
    int i = 0;
    do { t[i++] = (char)('0' + v % 10); v /= 10; } while (v);
    while (i) b[n++] = t[--i];
    return n;
}

static void write_line(const char *extra)
{
    char b[256], comm[17] = {0};
    size_t n = 0;
    int saved = errno;
    prctl(PR_GET_NAME, comm, 0, 0, 0);
    n = put_str(b, n, "pid=");
    n = put_num(b, n, (unsigned long)getpid());
    n = put_str(b, n, " comm=");
    n = put_str(b, n, comm);
    if (extra) {
        n = put_str(b, n, extra);
    } else {
        n = put_str(b, n, " signals=");
        n = put_num(b, n, atomic_load(&n_signals));
        n = put_str(b, n, " ssbs_clear=");
        n = put_num(b, n, atomic_load(&n_clear));
    }
    b[n++] = '\n';
    int fd = open(log_path, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0644);
    if (fd >= 0) {
        ssize_t r = write(fd, b, n);
        (void)r;
        close(fd);
    }
    errno = saved;
}

__attribute__((constructor)) static void ctor(void)
{
    init();
    if (observe && (getauxval(AT_HWCAP) & HWCAP_SSBS)) write_line(" hwcap_ssbs=1");
}

__attribute__((destructor)) static void dtor(void)
{
    if (observe) write_line(NULL);
}

static void trampoline(int sig, siginfo_t *info, void *uc_v)
{
#ifdef __aarch64__
    ucontext_t *uc = uc_v;
    if (observe) {
        unsigned long s = atomic_fetch_add(&n_signals, 1) + 1;
        if (!(uc->uc_mcontext.pstate & PSTATE_SSBS)) atomic_fetch_add(&n_clear, 1);
        if (s % LOG_EVERY == 0) write_line(NULL);
    }
#endif
    void *h = atomic_load_explicit(&real_handler[sig], memory_order_acquire);
    if (h) {
        if (atomic_load_explicit(&real_siginfo[sig], memory_order_relaxed))
            ((sigact_fn)h)(sig, info, uc_v);
        else
            ((sighand_fn)h)(sig);
    }
#ifdef __aarch64__
    if (!nofix) uc->uc_mcontext.pstate |= PSTATE_SSBS;
#endif
}

static int wrapped(void *h)
{
    return h != (void *)SIG_DFL && h != (void *)SIG_IGN && h != (void *)SIG_ERR;
}

int sigaction(int sig, const struct sigaction *act, struct sigaction *oldact)
{
    init();
    sigaction_fn next = atomic_load_explicit(&next_sigaction, memory_order_acquire);
    if (disabled || sig <= 0 || sig >= MAX_SIG) return next(sig, act, oldact);
    struct sigaction mine;
    const struct sigaction *pass = act;
    void *new_h = NULL;
    int new_info = 0, wrap = 0;
    if (act) {
        new_info = (act->sa_flags & SA_SIGINFO) != 0;
        new_h = new_info ? (void *)act->sa_sigaction : (void *)act->sa_handler;
        wrap = wrapped(new_h);
        if (wrap) {
            mine = *act;
            mine.sa_flags |= SA_SIGINFO;
            mine.sa_sigaction = trampoline;
            pass = &mine;
        }
    }
    void *prev_h = atomic_load(&real_handler[sig]);
    int prev_info = atomic_load(&real_siginfo[sig]);
    if (wrap) {
        atomic_store(&real_siginfo[sig], new_info);
        atomic_store_explicit(&real_handler[sig], new_h, memory_order_release);
    }
    int ret = next(sig, pass, oldact);
    if (ret != 0 && wrap) {
        atomic_store(&real_siginfo[sig], prev_info);
        atomic_store(&real_handler[sig], prev_h);
    }
    if (ret == 0 && oldact && oldact->sa_sigaction == trampoline && prev_h) {
        if (prev_info) {
            oldact->sa_sigaction = (sigact_fn)prev_h;
        } else {
            oldact->sa_flags &= ~SA_SIGINFO;
            oldact->sa_handler = (sighand_fn)prev_h;
        }
    }
    return ret;
}

int __sigaction(int sig, const struct sigaction *act, struct sigaction *oldact)
{
    return sigaction(sig, act, oldact);
}

static sighandler_t install(int sig, sighandler_t handler, int flags)
{
    struct sigaction sa, old;
    memset(&sa, 0, sizeof(sa));
    sa.sa_handler = handler;
    sa.sa_flags = flags;
    sigemptyset(&sa.sa_mask);
    if (sigaction(sig, &sa, &old) != 0) return SIG_ERR;
    return (old.sa_flags & SA_SIGINFO) ? (sighandler_t)(void *)old.sa_sigaction : old.sa_handler;
}

sighandler_t signal(int sig, sighandler_t handler) { return install(sig, handler, SA_RESTART); }
sighandler_t bsd_signal(int sig, sighandler_t handler) { return install(sig, handler, SA_RESTART); }
sighandler_t sysv_signal(int sig, sighandler_t handler) { return install(sig, handler, SA_RESETHAND | SA_NODEFER); }
sighandler_t __sysv_signal(int sig, sighandler_t handler) { return install(sig, handler, SA_RESETHAND | SA_NODEFER); }
