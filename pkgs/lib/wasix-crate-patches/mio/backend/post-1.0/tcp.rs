#![allow(dead_code)]
#[cfg(target_vendor = "wasmer")]
use ::wasix as wasi;
use std::io;
use std::net::{self, SocketAddr};
use std::os::wasi::io::{AsRawFd, FromRawFd};

use crate::sys::wasi::net::{new_socket, socket_addr, to_socket_addr};

pub(crate) fn new_for_addr(address: SocketAddr) -> io::Result<libc::c_int> {
    let domain = match address {
        SocketAddr::V4(_) => libc::AF_INET,
        SocketAddr::V6(_) => libc::AF_INET6,
    };
    new_socket(domain, libc::SOCK_STREAM)
}

pub(crate) fn bind(socket: &net::TcpListener, addr: SocketAddr) -> io::Result<()> {
    let addr = socket_addr(&addr);
    unsafe {
        wasi::sock_bind(socket.as_raw_fd() as u32, &addr)
            .map_err(|errno| io::Error::from_raw_os_error(errno.raw() as i32))
    }
}

pub(crate) fn connect(socket: &net::TcpStream, addr: SocketAddr) -> io::Result<()> {
    let addr = socket_addr(&addr);
    let res = unsafe { wasi::sock_connect(socket.as_raw_fd() as u32, &addr) };
    match res {
        // A connect on a non-blocking socket finishes asynchronously, which the
        // caller then waits for by polling writability.
        Err(errno) if errno.raw() as i32 != libc::EINPROGRESS => {
            Err(io::Error::from_raw_os_error(errno.raw() as i32))
        }
        _ => Ok(()),
    }
}

pub(crate) fn listen(socket: &net::TcpListener, backlog: i32) -> io::Result<()> {
    unsafe {
        wasi::sock_listen(socket.as_raw_fd() as u32, backlog as usize)
            .map_err(|errno| io::Error::from_raw_os_error(errno.raw() as i32))
    }
}

pub(crate) fn set_reuseaddr(socket: &net::TcpListener, reuseaddr: bool) -> io::Result<()> {
    let val = if reuseaddr {
        wasi::BOOL_TRUE
    } else {
        wasi::BOOL_FALSE
    };
    unsafe {
        wasi::sock_set_opt_flag(socket.as_raw_fd() as u32, wasi::SOCK_OPTION_REUSE_ADDR, val)
            .map_err(|errno| io::Error::from_raw_os_error(errno.raw() as i32))
    }
}

pub(crate) fn accept(listener: &net::TcpListener) -> io::Result<(net::TcpStream, SocketAddr)> {
    let (socket, addr) = unsafe {
        wasi::sock_accept_v2(listener.as_raw_fd() as u32, wasi::FDFLAGS_NONBLOCK)
            .map_err(|errno| io::Error::from_raw_os_error(errno.raw() as i32))?
    };

    Ok((
        unsafe { net::TcpStream::from_raw_fd(socket as i32) },
        to_socket_addr(&addr)?,
    ))
}
