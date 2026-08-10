use crate::{Interest, Token};

use log::error;
#[cfg(debug_assertions)]
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::time::Duration;
use std::{i32, io, ptr};
use std::os::fd::RawFd;
use std::os::fd::AsRawFd;

use ::wasix as wasi;

/// Unique id for use as `SelectorId`.
#[cfg(debug_assertions)]
static NEXT_ID: AtomicUsize = AtomicUsize::new(1);

#[derive(Debug)]
pub struct Selector {
    #[cfg(debug_assertions)]
    id: usize,
    ep: wasi::Fd,
    #[cfg(debug_assertions)]
    has_waker: AtomicBool,
}

impl Selector {
    pub fn new() -> io::Result<Selector> {
        let ep = unsafe {
            wasi::epoll_create()
        }.map_err(io_err)?;
        Ok(
            Selector {
                #[cfg(debug_assertions)]
                id: NEXT_ID.fetch_add(1, Ordering::Relaxed),
                ep,
                #[cfg(debug_assertions)]
                has_waker: AtomicBool::new(false),
            }
        )
    }

    pub fn try_clone(&self) -> io::Result<Selector> {
        let ep = unsafe {
            wasi::fd_dup(self.ep)
        }.map_err(io_err)?;
        Ok(
            Selector {
                // It's the same selector, so we use the same id.
                #[cfg(debug_assertions)]
                id: self.id,
                ep,
                #[cfg(debug_assertions)]
                has_waker: AtomicBool::new(self.has_waker.load(Ordering::Acquire)),
            }
        )
    }

    pub fn select(&self, events: &mut Events, timeout: Option<Duration>) -> io::Result<()> {
        let timeout = timeout
            .map(|to| to.as_nanos() as wasi::Timestamp)
            .unwrap_or(wasi::Timestamp::MAX);

        events.clear();
        unsafe {
            wasi::epoll_wait(
                self.ep,
                events.as_mut_ptr(),
                events.capacity(),
                timeout
            )
        }
        .map_err(io_err)
        .map(|n_events| {
            // This is safe because `epoll_wait` ensures that `n_events` are
            // assigned.
            unsafe { events.set_len(n_events as usize) };
        })
    }

    pub fn register(&self, fd: wasi::Fd, token: Token, interests: Interest) -> io::Result<()> {
        let mut event = wasi::EpollEvent {
            events: interests_to_epoll(interests),
            data: wasi::EpollData {
                ptr: 0,
                fd: fd,
                data1: 0,
                data2: usize::from(token) as u64,
            }   
        };

        unsafe {
            wasi::epoll_ctl(
                self.ep,
                wasi::EPOLL_CTL_ADD,
                fd,
                &mut event
            )
            .map(|_| ())
        }
        .map_err(io_err)
    }

    pub fn reregister(&self, fd: wasi::Fd, token: Token, interests: Interest) -> io::Result<()> {
        let mut event = wasi::EpollEvent {
            events: interests_to_epoll(interests),
            data: wasi::EpollData {
                ptr: 0,
                fd: fd,
                data1: 0,
                data2: usize::from(token) as u64,
            }
        };

        unsafe {
            wasi::epoll_ctl(
                self.ep,
                wasi::EPOLL_CTL_MOD,
                fd,
                &mut event
            )
            .map(|_| ())
        }
        .map_err(io_err)
    }

    pub fn deregister(&self, fd: wasi::Fd) -> io::Result<()> {
        unsafe {
            wasi::epoll_ctl(
                self.ep,
                wasi::EPOLL_CTL_DEL,
                fd,
                ptr::null_mut()
            )
            .map(|_| ())
        }
        .map_err(io_err)
    }

    #[cfg(debug_assertions)]
    pub fn register_waker(&self) -> bool {
        self.has_waker.swap(true, Ordering::AcqRel)
    }
}

cfg_io_source! {
    impl Selector {
        #[cfg(debug_assertions)]
        pub fn id(&self) -> usize {
            self.id
        }
    }
}

impl AsRawFd for Selector {
    fn as_raw_fd(&self) -> RawFd {
        self.ep as RawFd
    }
}

impl Drop for Selector {
    fn drop(&mut self) {
        if let Err(err) = unsafe {
            wasi::fd_close(
                self.ep,
            )
            .map(|_| ())
        } {
            error!("error closing epoll: {}", err);
        }
    }
}

fn interests_to_epoll(interests: Interest) -> u32 {
    let mut kind = wasi::EPOLL_TYPE_EPOLLET;

    if interests.is_readable() {
        kind = kind | wasi::EPOLL_TYPE_EPOLLIN | wasi::EPOLL_TYPE_EPOLLRDHUP;
    }

    if interests.is_writable() {
        kind |= wasi::EPOLL_TYPE_EPOLLOUT;
    }

    kind as u32
}

pub(crate) type Events = Vec<Event>;

pub(crate) type Event = wasi::EpollEvent;

pub(crate) mod event {
    use std::fmt;
    use ::wasix as wasi;

    use crate::sys::Event;
    use crate::Token;

    pub(crate) fn token(event: &Event) -> Token {
        Token(event.data.data2 as usize)
    }

    pub(crate) fn is_readable(event: &Event) -> bool {
        (event.events & wasi::EPOLL_TYPE_EPOLLIN) != 0 ||
        (event.events & wasi::EPOLL_TYPE_EPOLLPRI) != 0
    }

    pub(crate) fn is_writable(event: &Event) -> bool {
        (event.events & wasi::EPOLL_TYPE_EPOLLOUT) != 0
    }

    pub(crate) fn is_error(event: &Event) -> bool {
        (event.events & wasi::EPOLL_TYPE_EPOLLERR) != 0
    }

    pub(crate) fn is_read_closed(event: &Event) -> bool {
        // Both halves of the socket have closed
        (event.events & wasi::EPOLL_TYPE_EPOLLHUP) != 0
            // Socket has received FIN or called shutdown(SHUT_RD)
            || ((event.events & wasi::EPOLL_TYPE_EPOLLIN) != 0
                && (event.events & wasi::EPOLL_TYPE_EPOLLRDHUP) != 0)
    }

    pub(crate) fn is_write_closed(event: &Event) -> bool {
        // Both halves of the socket have closed
        (event.events & wasi::EPOLL_TYPE_EPOLLHUP) != 0
            // Unix pipe write end has closed
            || ((event.events & wasi::EPOLL_TYPE_EPOLLOUT) != 0
                && (event.events & wasi::EPOLL_TYPE_EPOLLERR) != 0)
            // The other side (read end) of a Unix pipe has closed.
            || (event.events & wasi::EPOLL_TYPE_EPOLLERR) != 0
    }

    pub(crate) fn is_priority(event: &Event) -> bool {
        (event.events & wasi::EPOLL_TYPE_EPOLLPRI) != 0
    }

    pub(crate) fn is_aio(_: &Event) -> bool {
        // Not supported.
        false
    }

    pub(crate) fn is_lio(_: &Event) -> bool {
        // Not supported.
        false
    }

    pub(crate) fn debug_details(f: &mut fmt::Formatter<'_>, event: &Event) -> fmt::Result {
        f.debug_struct("Event")
            .field("fd", &event.data.fd)
            .finish()
    }
}

fn io_err(errno: wasi::x::Errno) -> io::Error {
    io::Error::from_raw_os_error(errno.raw() as i32)
}
