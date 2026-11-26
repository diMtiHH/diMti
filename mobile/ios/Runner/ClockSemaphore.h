#ifndef UniverseClockSemaphore_h
#define UniverseClockSemaphore_h
#include <errno.h>
#include <fcntl.h>
#include <semaphore.h>
#include <sys/stat.h>

// No wait/post or shared data: existence is a kernel-lifetime marker only.
// The fixed C signature avoids importing sem_open's variadic creation API.
static inline int universe_clock_semaphore(const char *name, int create) {
  sem_t *handle = create ? sem_open(name, O_CREAT | O_EXCL, S_IRUSR | S_IWUSR, 0)
                        : sem_open(name, 0);
  if (handle == SEM_FAILED) return errno;
  return sem_close(handle) == 0 ? 0 : errno;
}
#endif
