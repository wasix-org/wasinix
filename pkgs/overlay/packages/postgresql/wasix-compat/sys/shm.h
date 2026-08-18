#ifndef _WASIX_COMPAT_SYS_SHM_H
#define _WASIX_COMPAT_SYS_SHM_H
#include <stddef.h>
#include <sys/ipc.h>
#include <sys/types.h>

#define SHM_RDONLY 010000
#define SHM_RND 020000

typedef unsigned long shmatt_t;

struct shmid_ds {
  struct ipc_perm shm_perm;
  size_t shm_segsz;
  time_t shm_atime;
  time_t shm_dtime;
  time_t shm_ctime;
  pid_t shm_cpid;
  pid_t shm_lpid;
  shmatt_t shm_nattch;
};

int shmget(key_t key, size_t size, int flag);
void *shmat(int id, const void *addr, int flag);
int shmdt(const void *addr);
int shmctl(int id, int cmd, struct shmid_ds *buf);

#endif
