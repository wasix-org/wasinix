#![allow(dead_code)]
use std::io;
use std::net::{Ipv4Addr, Ipv6Addr, SocketAddr, SocketAddrV4, SocketAddrV6};
#[cfg(target_vendor = "wasmer")]
use ::wasix as wasi;

pub(crate) fn new_ip_socket(addr: SocketAddr, socket_type: libc::c_int) -> io::Result<libc::c_int> {
    let domain = match addr {
        SocketAddr::V4(..) => libc::AF_INET,
        SocketAddr::V6(..) => libc::AF_INET6,
    };

    new_socket(domain, socket_type)
}

pub(crate) fn wasi_address_type(domain: libc::c_int) -> io::Result<wasi::AddressFamily> {
    Ok(
        match domain {
            libc::AF_INET => wasi::ADDRESS_FAMILY_INET4,
            libc::AF_INET6 => wasi::ADDRESS_FAMILY_INET6,
            libc::AF_UNSPEC => wasi::ADDRESS_FAMILY_UNSPEC,
            libc::AF_UNIX => wasi::ADDRESS_FAMILY_UNIX,
            _ => return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                "address family is unknown",
            ))
        }
    )
}

pub(crate) fn wasi_socket_type(socket_type: libc::c_int) -> io::Result<wasi::SockType> {
    Ok(
        match socket_type {
            libc::SOCK_STREAM => wasi::SOCK_TYPE_SOCKET_STREAM,
            libc::SOCK_DGRAM => wasi::SOCK_TYPE_SOCKET_DGRAM,
            libc::SOCK_RAW => wasi::SOCK_TYPE_SOCKET_RAW,
            _ => return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                "socket type is unknown",
            ))
        }
    )
}

/// Create a new non-blocking socket.
pub(crate) fn new_socket(domain: libc::c_int, socket_type: libc::c_int) -> io::Result<libc::c_int> {
    let proto = match socket_type {
        libc::SOCK_STREAM => wasi::SOCK_PROTO_TCP,
        libc::SOCK_DGRAM => wasi::SOCK_PROTO_UDP,
        libc::SOCK_RAW if domain == libc::AF_INET => wasi::SOCK_PROTO_IP,
        libc::SOCK_RAW if domain == libc::AF_INET6 => wasi::SOCK_PROTO_IPV6,
        libc::SOCK_RAW if domain == libc::AF_UNSPEC => wasi::SOCK_PROTO_IPV6,
        _ => return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "unsupported socket protocol",
        ))
    };

    let socket = unsafe {
        wasi::sock_open(
            wasi_address_type(domain)?,
            wasi_socket_type(socket_type)?,
            proto
        ).map_err(|errno| io::Error::from_raw_os_error(errno.raw() as i32))?
    };

    Ok(
        socket as libc::c_int
    )
}

/// A type with the same memory layout as `libc::sockaddr`. Used in converting Rust level
/// SocketAddr* types into their system representation. The benefit of this specific
/// type over using `libc::sockaddr_storage` is that this type is exactly as large as it
/// needs to be and not a lot larger. And it can be initialized cleaner from Rust.
#[repr(C)]
pub(crate) union SocketAddrCRepr {
    v4: libc::sockaddr_in,
    v6: libc::sockaddr_in6,
}

impl SocketAddrCRepr {
    pub(crate) fn as_ptr(&self) -> *const libc::sockaddr {
        self as *const _ as *const libc::sockaddr
    }
}

/// Converts a Rust `SocketAddr` into the system representation.
pub(crate) fn socket_addr(addr: &SocketAddr) -> wasi::AddrPort {
    match addr {
        SocketAddr::V4(ref addr) => {
            let o = addr.ip().octets();
            wasi::AddrPort {
                tag: wasi::ADDRESS_FAMILY_INET4.raw(),
                u: wasi::AddrPortU {
                    inet4: wasi::AddrIp4Port {
                        port: addr.port(),
                        addr: wasi::AddrIp4 {
                            n0: o[0],
                            n1: o[1],
                            h0: o[2],
                            h1: o[3],
                        }
                    }
                }
            }
        }
        SocketAddr::V6(ref addr) => {
            let s = addr.ip().segments();
            wasi::AddrPort {
                tag: wasi::ADDRESS_FAMILY_INET6.raw(),
                u: wasi::AddrPortU {
                    inet6: wasi::AddrIp6Port {
                        port: addr.port(),
                        addr: wasi::AddrIp6 {
                            n0: s[0],
                            n1: s[1],
                            n2: s[2],
                            n3: s[3],
                            h0: s[4],
                            h1: s[5],
                            h2: s[6],
                            h3: s[7],
                        }
                    }
                }
            }
        }
    }
}

/// Converts a `libc::sockaddr` compatible struct into a native Rust `SocketAddr`.
///
pub(crate) fn to_socket_addr(addr: &wasi::AddrPort) -> io::Result<SocketAddr> {
    unsafe {
        let addr = *addr;
        match addr.tag {
            a if a == wasi::ADDRESS_FAMILY_INET4.raw() => {
                let port = addr.u.inet4.port;
                let ip = addr.u.inet4.addr;
                Ok(SocketAddr::V4(SocketAddrV4::new(
                    Ipv4Addr::new(
                        ip.n0,
                        ip.n1,
                        ip.h0,
                        ip.h1
                    ),
                    port
                )))
            }
            a if a == wasi::ADDRESS_FAMILY_INET6.raw() => {
                let port = addr.u.inet6.port;
                let ip = addr.u.inet6.addr;
                Ok(SocketAddr::V6(SocketAddrV6::new(
                    Ipv6Addr::new(
                        ip.n0,
                        ip.n1,
                        ip.n2,
                        ip.n3,
                        ip.h0,
                        ip.h1,
                        ip.h2,
                        ip.h3
                    ),
                    port,
                    0,
                    0
                )))
            }
            _ => Err(io::ErrorKind::InvalidInput.into()),
        }
    }
}
