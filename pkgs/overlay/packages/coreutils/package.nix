# GNU coreutils, the file/text/shell utilities git's shell subcommands and an
# interactive bash need on PATH. Built as a single binary with a symlink per
# program, so the webc carries one wasm and names a command per program.
#
# Off-EH profile only, like bash: several programs fork, which needs the
# asyncify pass, and binaryen's asyncify aborts on the Wasm-EH instructions the
# other profiles emit (see WASIX-TODO.md).
{
  prev,
  helpers,
  ...
}: let
  # Every installed program, i.e. `ls $out/bin` minus the binary itself and `[`
  # (which no shell needs from PATH and whose name the registry would have to
  # carry). Each becomes a webc command on the one module, so a dependent gets
  # /bin/<prog> for all of them without repeating the wasm.
  programs = [
    "b2sum"
    "base32"
    "base64"
    "basename"
    "basenc"
    "cat"
    "chcon"
    "chgrp"
    "chmod"
    "chown"
    "cksum"
    "comm"
    "cp"
    "csplit"
    "cut"
    "date"
    "dd"
    "df"
    "dir"
    "dircolors"
    "dirname"
    "du"
    "echo"
    "env"
    "expand"
    "expr"
    "factor"
    "false"
    "fmt"
    "fold"
    "groups"
    "head"
    "hostid"
    "id"
    "install"
    "join"
    "kill"
    "link"
    "ln"
    "logname"
    "ls"
    "md5sum"
    "mkdir"
    "mkfifo"
    "mknod"
    "mktemp"
    "mv"
    "nice"
    "nl"
    "nohup"
    "nproc"
    "numfmt"
    "od"
    "paste"
    "pathchk"
    "pr"
    "printenv"
    "printf"
    "ptx"
    "pwd"
    "readlink"
    "realpath"
    "rm"
    "rmdir"
    "runcon"
    "seq"
    "sha1sum"
    "sha224sum"
    "sha256sum"
    "sha384sum"
    "sha512sum"
    "shred"
    "shuf"
    "sleep"
    "sort"
    "split"
    "stat"
    "stty"
    "sum"
    "sync"
    "tac"
    "tail"
    "tee"
    "test"
    "timeout"
    "touch"
    "tr"
    "true"
    "truncate"
    "tsort"
    "tty"
    "uname"
    "unexpand"
    "uniq"
    "unlink"
    "uptime"
    "vdir"
    "wc"
    "whoami"
    "yes"
  ];
in
  helpers.extendPackage (prev.coreutils.override {gmpSupport = false;}) {
    passthru.wasinix.shipped = true;
    passthru.wasix.supportedProfiles = ["off"];
    passthru.wasmer.entrypoint = "coreutils";
    passthru.wasmer.commands =
      [{name = "coreutils";}]
      ++ map (p: {
        name = p;
        module = "coreutils";
        wasm = "coreutils.wasm";
        output = "coreutils.wasm";
      })
      programs;
    # libc.a carries a chroot symbol that the link probe finds, but no header
    # declares it, so chroot.c fails to compile. Drop the program instead; wasm
    # has nothing to chroot into. (who/users/pinky drop out on their own, since
    # WASIX has no utmp headers.)
    configureFlags = ["ac_cv_func_chroot=no"];

    postPatch = ''
          # Same gnulib gaps findutils hits: no mount table, and opendirat collides
          # with the wasix-libc symbol of that name.
          substituteInPlace configure \
            --replace-fail "printf '%s\n' \"#define MOUNTED_NOT_PORTED 1\" >>confdefs.h" \
                           'ac_list_mounted_fs=found'
          substituteInPlace lib/mountlist.c \
            --replace-fail 'struct mount_entry *mount_list;' \
                           'struct mount_entry *mount_list = NULL;'
          substituteInPlace lib/opendirat.c \
            --replace-fail 'opendirat (int dir_fd, char const *dir, int extra_flags, int *pnew_fd)' \
                           'rpl_opendirat (int dir_fd, char const *dir, int extra_flags, int *pnew_fd)'
          substituteInPlace lib/opendirat.h \
            --replace-fail 'DIR *opendirat (int, char const *, int, int *)' \
                           '#define opendirat rpl_opendirat
      DIR *rpl_opendirat (int, char const *, int, int *)'

          # wasix-libc is musl, but gnulib gates its musl branch (nl_langinfo_l with
          # NL_LOCALE_NAME) and the <langinfo.h> include on __linux__, so wasm32-wasi
          # falls through to the "Please port gnulib" #error.
          substituteInPlace lib/getlocalename_l-unsafe.c \
            --replace-fail '(defined __linux__ && HAVE_LANGINFO_H)' \
                           '((defined __linux__ || defined __wasi__) && HAVE_LANGINFO_H)' \
            --replace-fail '#elif defined __linux__ && HAVE_LANGINFO_H && defined NL_LOCALE_NAME' \
                           '#elif (defined __linux__ || defined __wasi__) && HAVE_LANGINFO_H && defined NL_LOCALE_NAME'
          substituteInPlace lib/getgroups.c \
            --replace-fail 'getgroups (_GL_UNUSED int n, _GL_UNUSED GETGROUPS_T *groups)' \
                           'getgroups (_GL_UNUSED int n, _GL_UNUSED gid_t *groups)'

          # wasix-libc has statvfs but no statfs, and its struct statvfs carries no
          # filesystem-type member, so stat.c's picker falls through to the
          # nonexistent struct statfs. Take the statvfs arm.
          substituteInPlace src/stat.c \
            --replace-fail '#if ((STAT_STATVFS || STAT_STATVFS64)' \
                           '#if 1 || ((STAT_STATVFS || STAT_STATVFS64)' \
            --replace-fail 'switch (statfsbuf->f_type)' 'switch (0) /* wasix: no fs-type member */' \
            --replace-fail 'unsigned long int type = statfsbuf->f_type;' \
                           'unsigned long int type = 0;'

          # --enable-single-binary compiles every program into the multi-call binary,
          # including ones configure left out of the install list, so a program that
          # does not compile has to drop out of noinst_LIBRARIES too. Edited in the
          # generated Makefile.in: touching src/single-binary.mk would demand automake.
          for prog in chroot pinky; do
            sed -i "/^@SINGLE_BINARY_TRUE@[[:space:]]*src\/libsinglebin_$prog\.a /d" Makefile.in
          done

          # The multi-call binary picks its program from argv[0], which for a module
          # run by path carries the .wasm the webc packaging requires.
          substituteInPlace src/coreutils.c \
            --replace-fail 'char *prog_name = last_component (argv[0]);' \
                           'char *prog_name = last_component (argv[0]);
        {
          char *ext = strrchr (prog_name, '"'"'.'"'"');
          if (ext && streq (ext, ".wasm"))
            *ext = 0;
        }'
    '';

    # gnulib's replacement prototypes disagree with wasix-libc's, and configure
    # cannot run a wasm probe for either.
    preConfigure = ''
      export ac_cv_func_getgroups=yes
    '';

    postInstall = ''
      mv "$out/bin/coreutils" "$out/bin/coreutils.wasm"
      # Every program is a symlink to the multi-call binary and dispatches on
      # argv[0]; renaming the target dangles them.
      for f in "$out/bin/"*; do
        [ -L "$f" ] || continue
        [ "$(readlink "$f")" = "coreutils" ] && ln -sf coreutils.wasm "$f"
      done
    '';
  }
