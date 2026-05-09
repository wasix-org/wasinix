/* Minimal sh for WASIX. Two modes:
     sh -c "cmd"           run a single command string (git's system()/popen())
     sh script args...     run a script file (git's ENOEXEC fallback retries
                           failed-as-wasm execs via SHELL_PATH+script-path)

   In -c mode we also replicate musl's ENOEXEC fallback: wasix-libc's execvp
   reports ENOEXEC for shebang scripts instead of interpreting them, so when
   the command would otherwise have been found via PATH we resolve it ourselves
   and feed it through our script handler. (Triggered by e.g. `git clone
   <local-path>`, which invokes `git-upload-pack` via sh.)

   The script handler understands only what's needed to ship the git alias
   scripts: skip blank/comment/shebang lines, execute a single `exec ... "$@"`
   line. Anything else is rejected. */
#include <ctype.h>
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#define MAX_ARGS 256

/* Parse a POSIX command string into argv, handling '' and "" quoting.
   Returns the number of arguments (argv is NULL-terminated). */
static char **parse_cmd(const char *cmd, int *argc_out) {
  char **argv = calloc(MAX_ARGS + 1, sizeof(char *));
  char *buf = malloc(strlen(cmd) + 1);
  if (!argv || !buf)
    return NULL;

  int argc = 0;
  int bi = 0;
  const char *p = cmd;

  while (*p) {
    while (*p && isspace((unsigned char)*p))
      p++;
    if (!*p)
      break;
    if (argc >= MAX_ARGS)
      break;

    bi = 0;
    while (*p) {
      if (*p == '\'') {
        p++;
        while (*p && *p != '\'')
          buf[bi++] = *p++;
        if (*p == '\'')
          p++;
      } else if (*p == '"') {
        p++;
        while (*p && *p != '"') {
          if (*p == '\\' && *(p + 1))
            p++;
          buf[bi++] = *p++;
        }
        if (*p == '"')
          p++;
      } else if (*p == '\\' && *(p + 1)) {
        p++;
        buf[bi++] = *p++;
      } else if (isspace((unsigned char)*p)) {
        break;
      } else {
        buf[bi++] = *p++;
      }
    }

    argv[argc] = malloc(bi + 1);
    if (!argv[argc]) {
      free(buf);
      return NULL;
    }
    memcpy(argv[argc], buf, bi);
    argv[argc][bi] = '\0';
    argc++;
  }

  argv[argc] = NULL;
  *argc_out = argc;
  free(buf);
  return argv;
}

/* PATH lookup: return malloc'd absolute path to name, or NULL. If name contains
   a '/', only that path is tried. Used to resolve the file after an ENOEXEC
   fallback, since execvp doesn't tell us which dir it actually tried. */
static char *find_in_path(const char *name) {
  if (strchr(name, '/'))
    return access(name, F_OK) == 0 ? strdup(name) : NULL;
  const char *path = getenv("PATH");
  if (!path || !*path)
    path = "/usr/local/bin:/bin:/usr/bin";
  char *dup = strdup(path);
  if (!dup)
    return NULL;
  char *saveptr = NULL;
  for (char *tok = strtok_r(dup, ":", &saveptr); tok; tok = strtok_r(NULL, ":", &saveptr)) {
    size_t n = strlen(tok) + 1 + strlen(name) + 1;
    char *cand = malloc(n);
    if (!cand)
      continue;
    snprintf(cand, n, "%s/%s", tok, name);
    if (access(cand, F_OK) == 0) {
      free(dup);
      return cand;
    }
    free(cand);
  }
  free(dup);
  return NULL;
}

/* Run a script file. Skips blank/comment/shebang lines. Executes the first
   `exec <cmd> ...` line by replacing the current process. `"$@"` (which parses
   as the bare token $@) expands to the positional params passed in. */
static int run_script(const char *path, int pos_argc, char *pos_argv[]) {
  FILE *fp = fopen(path, "r");
  if (!fp) {
    fprintf(stderr, "sh-shim: cannot open script '%s'\n", path);
    return 127;
  }

  char *line = NULL;
  size_t cap = 0;
  ssize_t len;

  while ((len = getline(&line, &cap, fp)) != -1) {
    if (len > 0 && line[len - 1] == '\n')
      line[--len] = '\0';
    if (len > 0 && line[len - 1] == '\r')
      line[--len] = '\0';

    const char *p = line;
    while (*p && isspace((unsigned char)*p))
      p++;
    if (*p == '\0' || *p == '#')
      continue;

    int line_argc = 0;
    char **line_argv = parse_cmd(p, &line_argc);
    if (!line_argv || line_argc == 0)
      continue;
    if (strcmp(line_argv[0], "exec") != 0 || line_argc < 2) {
      fprintf(stderr, "sh-shim: only `exec` lines are supported in scripts: %s\n", p);
      fclose(fp);
      free(line);
      return 1;
    }

    int new_argc = 0;
    for (int i = 1; i < line_argc; i++)
      new_argc += strcmp(line_argv[i], "$@") == 0 ? pos_argc : 1;

    char **new_argv = calloc(new_argc + 1, sizeof(char *));
    int j = 0;
    for (int i = 1; i < line_argc; i++) {
      if (strcmp(line_argv[i], "$@") == 0)
        for (int k = 0; k < pos_argc; k++) new_argv[j++] = pos_argv[k];
      else
        new_argv[j++] = line_argv[i];
    }
    new_argv[new_argc] = NULL;

    execvp(new_argv[0], new_argv);
    fprintf(stderr, "sh-shim: exec '%s' failed\n", new_argv[0]);
    return 127;
  }

  fclose(fp);
  free(line);
  return 0;
}

int main(int argc, char *argv[]) {
  if (argc >= 3 && strcmp(argv[1], "-c") == 0) {
    int n = 0;
    char **exec_argv = parse_cmd(argv[2], &n);
    if (!exec_argv || n == 0)
      return exec_argv ? 0 : 1;
    execvp(exec_argv[0], exec_argv);
    if (errno == ENOEXEC) {
      char *resolved = find_in_path(exec_argv[0]);
      if (resolved)
        return run_script(resolved, n - 1, &exec_argv[1]);
    }
    fprintf(stderr, "sh-shim: %s: %s\n", exec_argv[0], strerror(errno));
    return 127;
  }

  if (argc >= 2 && argv[1][0] != '-')
    return run_script(argv[1], argc - 2, &argv[2]);

  fprintf(stderr, "sh-shim: usage: sh -c CMD | sh SCRIPT ARGS\n");
  return 1;
}
