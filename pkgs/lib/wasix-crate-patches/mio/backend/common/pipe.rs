#![allow(dead_code)]
//! WASI pipe.
//!
//! See the [`new`] function for documentation.

use std::fs::File;
use std::io::{self, IoSlice, IoSliceMut, Read, Write};
use std::os::wasi::io::{AsRawFd, FromRawFd, IntoRawFd, RawFd};
#[cfg(target_vendor = "wasmer")]
use ::wasix as wasi;

use crate::io_source::IoSource;
use crate::{event, Interest, Registry, Token};

/// Create a new non-blocking WASI pipe.
///
pub fn new() -> io::Result<(Sender, Receiver)> {
    #[cfg(target_vendor = "wasmer")]
    let (fd1, fd2) = unsafe {
        wasi::fd_pipe()
            .map_err(|errno| io::Error::from_raw_os_error(errno.raw() as i32))?
    };

    #[cfg(not(target_vendor = "wasmer"))]
    let (fd1, fd2) = unsafe {
        wasi::pipe()
            .map_err(|errno| io::Error::from_raw_os_error(errno.raw() as i32))?
    };

    let r = unsafe { Receiver::from_raw_fd(fd1 as RawFd) };
    let w = unsafe { Sender::from_raw_fd(fd2 as RawFd) };
    Ok((w, r))
}

/// Sending end of an WASI pipe.
///
#[derive(Debug)]
pub struct Sender {
    inner: IoSource<File>,
}

impl Sender {
    /// Set the `Sender` into or out of non-blocking mode.
    pub fn set_nonblocking(&self, nonblocking: bool) -> io::Result<()> {
        set_nonblocking(self.inner.as_raw_fd(), nonblocking)
    }

    /// Execute an I/O operation ensuring that the socket receives more events
    /// if it hits a [`WouldBlock`] error.
    pub fn try_io<F, T>(&self, f: F) -> io::Result<T>
    where
        F: FnOnce() -> io::Result<T>,
    {
        self.inner.do_io(|_| f())
    }
}

impl event::Source for Sender {
    fn register(
        &mut self,
        registry: &Registry,
        token: Token,
        interests: Interest,
    ) -> io::Result<()> {
        self.inner.register(registry, token, interests)
    }

    fn reregister(
        &mut self,
        registry: &Registry,
        token: Token,
        interests: Interest,
    ) -> io::Result<()> {
        self.inner.reregister(registry, token, interests)
    }

    fn deregister(&mut self, registry: &Registry) -> io::Result<()> {
        self.inner.deregister(registry)
    }
}

impl Write for Sender {
    fn write(&mut self, buf: &[u8]) -> io::Result<usize> {
        self.inner.do_io(|sender| (&*sender).write(buf))
    }

    fn write_vectored(&mut self, bufs: &[IoSlice<'_>]) -> io::Result<usize> {
        self.inner.do_io(|sender| (&*sender).write_vectored(bufs))
    }

    fn flush(&mut self) -> io::Result<()> {
        self.inner.do_io(|sender| (&*sender).flush())
    }
}

impl Write for &Sender {
    fn write(&mut self, buf: &[u8]) -> io::Result<usize> {
        self.inner.do_io(|sender| (&*sender).write(buf))
    }

    fn write_vectored(&mut self, bufs: &[IoSlice<'_>]) -> io::Result<usize> {
        self.inner.do_io(|sender| (&*sender).write_vectored(bufs))
    }

    fn flush(&mut self) -> io::Result<()> {
        self.inner.do_io(|sender| (&*sender).flush())
    }
}

impl FromRawFd for Sender {
    unsafe fn from_raw_fd(fd: RawFd) -> Sender {
        Sender {
            inner: IoSource::new(File::from_raw_fd(fd)),
        }
    }
}

impl AsRawFd for Sender {
    fn as_raw_fd(&self) -> RawFd {
        self.inner.as_raw_fd()
    }
}

impl IntoRawFd for Sender {
    fn into_raw_fd(self) -> RawFd {
        self.inner.into_inner().into_raw_fd()
    }
}

#[derive(Debug)]
pub struct Receiver {
    inner: IoSource<File>,
}

impl Receiver {
    pub fn set_nonblocking(&self, nonblocking: bool) -> io::Result<()> {
        set_nonblocking(self.inner.as_raw_fd(), nonblocking)
    }

    pub fn try_io<F, T>(&self, f: F) -> io::Result<T>
    where
        F: FnOnce() -> io::Result<T>,
    {
        self.inner.do_io(|_| f())
    }
}

impl event::Source for Receiver {
    fn register(
        &mut self,
        registry: &Registry,
        token: Token,
        interests: Interest,
    ) -> io::Result<()> {
        self.inner.register(registry, token, interests)
    }

    fn reregister(
        &mut self,
        registry: &Registry,
        token: Token,
        interests: Interest,
    ) -> io::Result<()> {
        self.inner.reregister(registry, token, interests)
    }

    fn deregister(&mut self, registry: &Registry) -> io::Result<()> {
        self.inner.deregister(registry)
    }
}

impl Read for Receiver {
    fn read(&mut self, buf: &mut [u8]) -> io::Result<usize> {
        self.inner.do_io(|sender| (&*sender).read(buf))
    }

    fn read_vectored(&mut self, bufs: &mut [IoSliceMut<'_>]) -> io::Result<usize> {
        self.inner.do_io(|sender| (&*sender).read_vectored(bufs))
    }
}

impl Read for &Receiver {
    fn read(&mut self, buf: &mut [u8]) -> io::Result<usize> {
        self.inner.do_io(|sender| (&*sender).read(buf))
    }

    fn read_vectored(&mut self, bufs: &mut [IoSliceMut<'_>]) -> io::Result<usize> {
        self.inner.do_io(|sender| (&*sender).read_vectored(bufs))
    }
}

impl FromRawFd for Receiver {
    unsafe fn from_raw_fd(fd: RawFd) -> Receiver {
        Receiver {
            inner: IoSource::new(File::from_raw_fd(fd)),
        }
    }
}

impl AsRawFd for Receiver {
    fn as_raw_fd(&self) -> RawFd {
        self.inner.as_raw_fd()
    }
}

impl IntoRawFd for Receiver {
    fn into_raw_fd(self) -> RawFd {
        self.inner.into_inner().into_raw_fd()
    }
}

fn set_nonblocking(fd: RawFd, nonblocking: bool) -> io::Result<()> {
    let fdstat = unsafe {
        wasi::fd_fdstat_get(fd.as_raw_fd() as wasi::Fd)
            .map_err(|errno| io::Error::from_raw_os_error(errno.raw() as i32))?
    };

    let mut flags = fdstat.fs_flags;

    if nonblocking {
        flags |= wasi::FDFLAGS_NONBLOCK;
    } else {
        flags &= !wasi::FDFLAGS_NONBLOCK;
    }

    unsafe {
        wasi::fd_fdstat_set_flags(fd.as_raw_fd() as wasi::Fd, flags)
            .map_err(|errno| io::Error::from_raw_os_error(errno.raw() as i32))
    }
}
