#define _POSIX_C_SOURCE 200809L
#ifdef __APPLE__
#define _DARWIN_C_SOURCE 1
#endif
#include "ProcessSupport.h"
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <spawn.h>
#include <string.h>
#include <sys/file.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <unistd.h>

int droplet_spawn(const char *path, char *const argv[], char *const envp[],
                  pid_t *pid, int *output_fd) {
    int fds[2], rc;
    *pid = -1;
    *output_fd = -1;
    if (pipe(fds) == -1) return errno;
    /* Serialize spawn in Swift; every owned descriptor is close-on-exec. */
    if (fcntl(fds[0], F_SETFD, FD_CLOEXEC) == -1 ||
        fcntl(fds[1], F_SETFD, FD_CLOEXEC) == -1 ||
        fcntl(fds[0], F_SETFL, O_NONBLOCK) == -1) {
        rc = errno;
        close(fds[0]); close(fds[1]);
        return rc;
    }
    posix_spawn_file_actions_t actions;
    posix_spawnattr_t attr;
    rc = posix_spawn_file_actions_init(&actions);
    if (rc) goto close_pipe;
    rc = posix_spawnattr_init(&attr);
    if (rc) goto destroy_actions;
#define CHECK(call) do { rc = (call); if (rc) goto destroy_all; } while (0)
    CHECK(posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0));
    CHECK(posix_spawn_file_actions_adddup2(&actions, fds[1], STDOUT_FILENO));
    CHECK(posix_spawn_file_actions_adddup2(&actions, fds[1], STDERR_FILENO));
    CHECK(posix_spawn_file_actions_addclose(&actions, fds[0]));
    CHECK(posix_spawn_file_actions_addclose(&actions, fds[1]));
    sigset_t empty, defaults;
    sigemptyset(&empty);
    sigemptyset(&defaults);
    sigaddset(&defaults, SIGTERM); sigaddset(&defaults, SIGINT);
    sigaddset(&defaults, SIGHUP); sigaddset(&defaults, SIGPIPE);
    CHECK(posix_spawnattr_setsigmask(&attr, &empty));
    CHECK(posix_spawnattr_setsigdefault(&attr, &defaults));
    CHECK(posix_spawnattr_setpgroup(&attr, 0));
    /* The kernel establishes PGID == child PID BEFORE executing the program.
       setpgid() in the parent after Process.run() would race exec(). */
    CHECK(posix_spawnattr_setflags(&attr, POSIX_SPAWN_SETPGROUP |
           POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF));
    rc = posix_spawn(pid, path, &actions, &attr, argv, envp);
destroy_all:
    posix_spawnattr_destroy(&attr);
destroy_actions:
    posix_spawn_file_actions_destroy(&actions);
close_pipe:
    close(fds[1]);
    if (rc) { close(fds[0]); return rc; }
    *output_fd = fds[0];
    return 0;
#undef CHECK
}

int droplet_observe(pid_t pid, int *exited, int *exit_code) {
    if (pid <= 1) return EINVAL;
    siginfo_t info;
    memset(&info, 0, sizeof(info));
    *exited = 0;
    if (waitid(P_PID, (id_t)pid, &info, WEXITED | WNOHANG | WNOWAIT) == -1)
        return errno;
    if (info.si_pid == pid) {
        *exited = 1;
        *exit_code = info.si_code == CLD_EXITED ? info.si_status : 128 + info.si_status;
    }
    return 0;
}

int droplet_signal_group(pid_t pid, int signal_number) {
    if (pid <= 1 || pid == getpgrp()) return EINVAL;
    /* Caller must still own the unreaped child. No global name matching. */
    return kill(-pid, signal_number) == 0 ? 0 : errno;
}

int droplet_reap(pid_t pid) {
    int status;
    if (pid <= 1) return EINVAL;
    while (waitpid(pid, &status, 0) == -1) {
        if (errno != EINTR) return errno;
    }
    return 0;
}

int droplet_lock(const char *path) {
    int fd = open(path, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0600);
    if (fd < 0) return -2;
    struct stat st;
    if (fstat(fd, &st) != 0 || !S_ISREG(st.st_mode) || st.st_uid != getuid()) {
        close(fd); errno = EPERM; return -2;
    }
    if (flock(fd, LOCK_EX | LOCK_NB) != 0) {
        int e = errno;
        close(fd); errno = e;
        return (e == EWOULDBLOCK || e == EAGAIN) ? -1 : -2;
    }
    /* Never unlink a lock file: contenders must always lock the same inode. */
    return fd;
}
