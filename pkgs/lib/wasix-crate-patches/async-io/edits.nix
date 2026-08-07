# async-io: use the WASIX fd traits and polling backend. rustix deliberately
# exposes neither its socket API nor Unix fd configuration on WASI, so WASIX
# sockets use std and wasix-libc directly.
{adds, ...}: {
  edited = ["=2.6.0"];
  stock = ["<2.6.0"];
  forVersion = {floorPatch, ...}: {
    patches = [floorPatch];
    patchPhase = ''
      cp --no-preserve=mode ${./wasix.rs} src/reactor/wasix.rs

      substituteInPlace Cargo.toml --replace-fail \
        $'[dependencies.slab]\nversion = "0.4.2"' \
        $'[target.\'cfg(all(target_os = "wasi", target_vendor = "wasmer"))\'.dependencies.wasix]\nversion = "0.13"\n\n[dependencies.slab]\nversion = "0.4.2"'

      substituteInPlace src/lib.rs \
        --replace-fail \
          $'    path::Path,\n};\n\n#[cfg(windows)]' \
          $'    path::Path,\n};\n\n#[cfg(all(target_os = "wasi", target_vendor = "wasmer"))]\nuse std::os::wasi::io::{AsFd, AsRawFd, BorrowedFd, OwnedFd, RawFd};\n\n#[cfg(windows)]' \
        --replace-fail \
          $'use rustix::io as rio;\nuse rustix::net as rn;\nuse rustix::net::addr::SocketAddrArg;' \
          $'use rustix::io as rio;\n#[cfg(not(all(target_os = "wasi", target_vendor = "wasmer")))]\nuse rustix::net as rn;\n#[cfg(not(all(target_os = "wasi", target_vendor = "wasmer")))]\nuse rustix::net::addr::SocketAddrArg;' \
        --replace-fail \
          $'#[cfg(unix)]\nimpl<T: AsFd> Async<T> {' \
          $'#[cfg(any(unix, all(target_os = "wasi", target_vendor = "wasmer")))]\nimpl<T: AsFd> Async<T> {' \
        --replace-fail \
          $'#[cfg(unix)]\nimpl<T: AsRawFd> AsRawFd for Async<T> {' \
          $'#[cfg(any(unix, all(target_os = "wasi", target_vendor = "wasmer")))]\nimpl<T: AsRawFd> AsRawFd for Async<T> {' \
        --replace-fail \
          $'#[cfg(unix)]\nimpl<T: AsFd> AsFd for Async<T> {' \
          $'#[cfg(any(unix, all(target_os = "wasi", target_vendor = "wasmer")))]\nimpl<T: AsFd> AsFd for Async<T> {' \
        --replace-fail \
          $'#[cfg(unix)]\nimpl<T: AsFd + From<OwnedFd>> TryFrom<OwnedFd> for Async<T> {' \
          $'#[cfg(any(unix, all(target_os = "wasi", target_vendor = "wasmer")))]\nimpl<T: AsFd + From<OwnedFd>> TryFrom<OwnedFd> for Async<T> {' \
        --replace-fail \
          $'#[cfg(unix)]\nimpl<T: Into<OwnedFd>> TryFrom<Async<T>> for OwnedFd {' \
          $'#[cfg(any(unix, all(target_os = "wasi", target_vendor = "wasmer")))]\nimpl<T: Into<OwnedFd>> TryFrom<Async<T>> for OwnedFd {' \
        --replace-fail \
          $'fn connect(\n    addr: rn::SocketAddrAny,' \
          $'#[cfg(not(all(target_os = "wasi", target_vendor = "wasmer")))]\nfn connect(\n    addr: rn::SocketAddrAny,'

      substituteInPlace src/reactor.rs --replace-fail \
        $'    if #[cfg(windows)] {\n        mod windows;\n        pub use windows::Registration;\n    } else if #[cfg(any(' \
        $'    if #[cfg(windows)] {\n        mod windows;\n        pub use windows::Registration;\n    } else if #[cfg(all(target_os = "wasi", target_vendor = "wasmer"))] {\n        mod wasix;\n        pub use wasix::Registration;\n    } else if #[cfg(any('
    '';
    adds = [adds.wasix];
  };
}
