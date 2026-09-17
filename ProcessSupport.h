#ifndef DROPLET_PROCESS_SUPPORT_H
#define DROPLET_PROCESS_SUPPORT_H
#include <sys/types.h>
/* Functions return errno values (0 on success), except droplet_lock. */
int droplet_spawn(const char *path, char *const argv[], char *const envp[],
                  pid_t *pid, int *output_fd);
/* Observe without reaping: the leader's PID remains reserved for safe group signals. */
int droplet_observe(pid_t pid, int *exited, int *exit_code);
int droplet_signal_group(pid_t pid, int signal_number);
int droplet_reap(pid_t pid);
/* >=0: locked fd, -1: another instance, -2: actual error (errno retained). */
int droplet_lock(const char *path);
#endif
