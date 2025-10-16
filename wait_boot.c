// wait_boot.c — waits for sys.boot_completed, logs time, then runs hotspot script
#include <unistd.h>
#include <fcntl.h>
#include <string.h>
#include <time.h>
#include <sys/system_properties.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <errno.h>
#include <stdio.h>

static void append(const char *path, const char *s) {
  int fd = open(path, O_WRONLY|O_CREAT|O_APPEND, 0644);
  if (fd >= 0) { write(fd, s, strlen(s)); close(fd); }
}

int main(void) {
  char v[PROP_VALUE_MAX] = {0};
  for (;;) {
    if (__system_property_get("sys.boot_completed", v) > 0 && v[0] == '1') break;
    sleep(2);
  }
  sleep(60);
  // write timestamp
  time_t t = time(NULL);
  struct tm tm; localtime_r(&t, &tm);
  char line[64]; strftime(line, sizeof(line), "%Y-%m-%d %H:%M:%S\n", &tm);
  append("/data/local/tmp/boot_time.txt", line);

  // fork and exec hotspot script (no shell in init; we launch it ourselves)
  pid_t pid = fork();
  if (pid == 0) {
    // child: exec /system/bin/sh /system/etc/init.hotspot.sh with a sane env
    char *argv[] = { (char*)"/system/bin/sh", (char*)"/system/etc/init.hotspot.sh", NULL };
    char *envp[] = {
      (char*)"PATH=/system/bin:/vendor/bin:/system/xbin",
      (char*)"LD_LIBRARY_PATH=/system/lib:/vendor/lib",
      NULL
    };
    // optional: small breadcrumb
    append("/data/local/tmp/hotspot_exec.log", "exec hotspot\n");
    execve("/system/bin/sh", argv, envp);
    // if we got here, exec failed — log errno
    char err[64];
    int n = snprintf(err, sizeof(err), "exec fail: %d\n", errno);
    append("/data/local/tmp/hotspot_exec.log", err);
    _exit(127);
  }
  // parent: don’t wait; let child run independently
  return 0;
}
