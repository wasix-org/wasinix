/*
 * System V shared memory for a single WASIX process. WASIX has no IPC
 * namespace and its fork() copies the linear memory, so a segment can neither
 * be shared nor outlive this process: segments live on the heap, and a key
 * this process did not create reports ENOENT.
 */
#include <errno.h>
#include <stdlib.h>
#include <string.h>
#include <sys/shm.h>

struct segment {
  struct segment *next;
  int id;
  key_t key;
  size_t size;
  void *addr;
  unsigned long nattch;
  int removed;
};

static struct segment *segments;
static int next_id = 1;

static struct segment *find_id(int id) {
  for (struct segment *s = segments; s != NULL; s = s->next)
    if (s->id == id)
      return s;
  return NULL;
}

static struct segment *find_key(key_t key) {
  for (struct segment *s = segments; s != NULL; s = s->next)
    if (!s->removed && s->key == key)
      return s;
  return NULL;
}

static void release(struct segment *seg) {
  if (!seg->removed || seg->nattch != 0)
    return;
  for (struct segment **link = &segments; *link != NULL; link = &(*link)->next)
    if (*link == seg) {
      *link = seg->next;
      break;
    }
  free(seg->addr);
  free(seg);
}

int shmget(key_t key, size_t size, int flag) {
  struct segment *seg = key == IPC_PRIVATE ? NULL : find_key(key);

  if (seg != NULL) {
    if ((flag & IPC_CREAT) && (flag & IPC_EXCL)) {
      errno = EEXIST;
      return -1;
    }
    if (size > seg->size) {
      errno = EINVAL;
      return -1;
    }
    return seg->id;
  }

  if (!(flag & IPC_CREAT)) {
    errno = ENOENT;
    return -1;
  }
  if (size == 0) {
    errno = EINVAL;
    return -1;
  }

  seg = calloc(1, sizeof(*seg));
  if (seg == NULL) {
    errno = ENOMEM;
    return -1;
  }
  seg->addr = calloc(1, size);
  if (seg->addr == NULL) {
    free(seg);
    errno = ENOMEM;
    return -1;
  }
  seg->id = next_id++;
  seg->key = key;
  seg->size = size;
  seg->next = segments;
  segments = seg;
  return seg->id;
}

void *shmat(int id, const void *addr, int flag) {
  (void)flag;
  struct segment *seg = find_id(id);

  if (seg == NULL || (addr != NULL && addr != seg->addr)) {
    errno = EINVAL;
    return (void *)-1;
  }
  seg->nattch++;
  return seg->addr;
}

int shmdt(const void *addr) {
  for (struct segment *seg = segments; seg != NULL; seg = seg->next)
    if (seg->addr == addr) {
      if (seg->nattch > 0)
        seg->nattch--;
      release(seg);
      return 0;
    }
  errno = EINVAL;
  return -1;
}

int shmctl(int id, int cmd, struct shmid_ds *buf) {
  struct segment *seg = find_id(id);

  if (seg == NULL) {
    errno = EINVAL;
    return -1;
  }

  switch (cmd) {
  case IPC_STAT:
    if (buf == NULL) {
      errno = EFAULT;
      return -1;
    }
    memset(buf, 0, sizeof(*buf));
    buf->shm_perm.__key = seg->key;
    buf->shm_segsz = seg->size;
    buf->shm_nattch = seg->nattch;
    return 0;
  case IPC_RMID:
    seg->removed = 1;
    release(seg);
    return 0;
  default:
    errno = EINVAL;
    return -1;
  }
}
