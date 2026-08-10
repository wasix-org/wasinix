#![allow(dead_code)]
use crate::sys::wasi::net::{new_ip_socket, socket_addr};

use std::io;
use std::net::{self, SocketAddr};
use std::os::wasi::io::{AsRawFd, FromRawFd};
#[cfg(target_vendor = "wasmer")]
use ::wasix as wasi;

pub fn bind(addr: SocketAddr) -> io::Result<net::UdpSocket> {
    let socket = new_ip_socket(addr, libc::SOCK_DGRAM)?;

    let addr = socket_addr(&addr);
    Ok(
        unsafe {
            wasi::sock_bind(
                socket.as_raw_fd() as u32,
                &addr
            ).map_err(|errno| io::Error::from_raw_os_error(errno.raw() as i32))?;

            net::UdpSocket::from_raw_fd(socket)
        }
    )
}

pub(crate) fn only_v6(socket: &net::UdpSocket) -> io::Result<bool> {
    let val = unsafe {
        wasi::sock_get_opt_flag(
            socket.as_raw_fd() as u32,
            wasi::SOCK_OPTION_ONLY_V6,
        ).map_err(|errno| io::Error::from_raw_os_error(errno.raw() as i32))
    }?;

    Ok(val != wasi::BOOL_FALSE)
}
