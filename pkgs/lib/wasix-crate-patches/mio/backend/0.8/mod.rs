//! # Notes
//!
//! The current implementation is somewhat limited. The `Waker` is not
//! implemented, as at the time of writing there is no way to support to wake-up
//! a thread from calling `poll_oneoff`.
//!
//! Furthermore the (re/de)register functions also don't work while concurrently
//! polling as both registering and polling requires a lock on the
//! `subscriptions`.
//!
//! Finally `Selector::try_clone`, required by `Registry::try_clone`, doesn't
//! work. However this could be implemented by use of an `Arc`.
//!
//! In summary, this only (barely) works using a single thread.

use std::io;

#[cfg(all(feature = "net", target_vendor = "unknown"))]
use crate::{Interest, Token};

#[cfg(target_vendor = "unknown")]
cfg_net! {
    pub(crate) mod tcp {
        use std::io;
        use std::net::{self, SocketAddr};

        pub(crate) fn accept(listener: &net::TcpListener) -> io::Result<(net::TcpStream, SocketAddr)> {
            let (stream, addr) = listener.accept()?;
            stream.set_nonblocking(true)?;
            Ok((stream, addr))
        }
    }
}

#[cfg(target_vendor = "wasmer")]
cfg_os_poll! {
    pub(crate) mod sourcefd;
    pub use self::sourcefd::SourceFd;
    
    pub(crate) mod waker;
    pub(crate) use self::waker::Waker;

    #[cfg(target_vendor = "wasmer")]
    #[path = "epoll.rs"]
    pub(crate) mod poll;
    #[cfg(not(target_vendor = "wasmer"))]
    pub(crate) mod poll;
    pub(crate) use poll::*;

    cfg_net! {
        mod net;
        pub(crate) mod tcp;
        pub(crate) mod udp;
        pub(crate) mod pipe;
    }
}

cfg_os_poll! {
    cfg_io_source! {
        pub(crate) struct IoSourceState;

        impl IoSourceState {
            pub(crate) fn new() -> IoSourceState {
                IoSourceState
            }

            pub(crate) fn do_io<T, F, R>(&self, f: F, io: &T) -> io::Result<R>
            where
                F: FnOnce(&T) -> io::Result<R>,
            {
                // We don't hold state, so we can just call the function and
                // return.
                f(io)
            }
        }
    }
}
