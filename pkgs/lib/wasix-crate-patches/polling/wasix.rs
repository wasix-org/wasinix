//! WASIX epoll backend.

use std::convert::TryInto;
use std::fs::File;
use std::io::{self, Read, Write};
use std::os::wasi::io::{AsFd, AsRawFd, BorrowedFd, FromRawFd, RawFd};
use std::time::Instant;

use ::wasix as wasi;

use crate::{Event, PollMode};

/// Interface to WASIX epoll.
#[derive(Debug)]
pub struct Poller {
    epoll_fd: wasi::Fd,
    notifier: File,
}

impl Poller {
    /// Creates a new poller.
    pub fn new() -> io::Result<Poller> {
        let epoll_fd = unsafe { wasi::epoll_create() }.map_err(io_err)?;
        let notifier_fd = match unsafe { wasi::fd_event(0, 0) } {
            Ok(fd) => fd,
            Err(errno) => {
                let _ = unsafe { wasi::fd_close(epoll_fd) };
                return Err(io_err(errno));
            }
        };
        let fdstat = match unsafe { wasi::fd_fdstat_get(notifier_fd) } {
            Ok(fdstat) => fdstat,
            Err(errno) => {
                let _ = unsafe { wasi::fd_close(epoll_fd) };
                let _ = unsafe { wasi::fd_close(notifier_fd) };
                return Err(io_err(errno.into()));
            }
        };
        if let Err(errno) = unsafe {
            wasi::fd_fdstat_set_flags(
                notifier_fd,
                fdstat.fs_flags | wasi::FDFLAGS_NONBLOCK,
            )
        } {
            let _ = unsafe { wasi::fd_close(epoll_fd) };
            let _ = unsafe { wasi::fd_close(notifier_fd) };
            return Err(io_err(errno.into()));
        }

        let notifier = unsafe { File::from_raw_fd(notifier_fd as RawFd) };
        let poller = Poller { epoll_fd, notifier };
        unsafe {
            poller.add(
                poller.notifier.as_raw_fd(),
                Event::readable(crate::NOTIFY_KEY),
                PollMode::Oneshot,
            )?;
        }
        Ok(poller)
    }

    /// Whether this poller supports level-triggered events.
    pub fn supports_level(&self) -> bool {
        true
    }

    /// Whether this poller supports edge-triggered events.
    pub fn supports_edge(&self) -> bool {
        true
    }

    /// Adds a new file descriptor.
    pub unsafe fn add(&self, fd: RawFd, ev: Event, mode: PollMode) -> io::Result<()> {
        self.ctl(wasi::EPOLL_CTL_ADD, fd, ev, mode)
    }

    /// Modifies an existing file descriptor.
    pub fn modify(&self, fd: BorrowedFd<'_>, ev: Event, mode: PollMode) -> io::Result<()> {
        self.ctl(wasi::EPOLL_CTL_MOD, fd.as_raw_fd(), ev, mode)
    }

    /// Deletes a file descriptor.
    pub fn delete(&self, fd: BorrowedFd<'_>) -> io::Result<()> {
        unsafe {
            wasi::epoll_ctl(
                self.epoll_fd,
                wasi::EPOLL_CTL_DEL,
                fd.as_raw_fd() as wasi::Fd,
                std::ptr::null(),
            )
        }
        .map_err(io_err)
    }

    fn ctl(&self, op: wasi::EpollCtl, fd: RawFd, ev: Event, mode: PollMode) -> io::Result<()> {
        let mut event = wasi::EpollEvent {
            events: epoll_flags(&ev, mode) | ev.extra.flags,
            data: wasi::EpollData {
                ptr: 0,
                fd: fd as wasi::Fd,
                data1: 0,
                data2: ev.key as u64,
            },
        };
        unsafe { wasi::epoll_ctl(self.epoll_fd, op, fd as wasi::Fd, &mut event) }.map_err(io_err)
    }

    /// Waits for I/O events with an optional deadline.
    pub fn wait_deadline(&self, events: &mut Events, deadline: Option<Instant>) -> io::Result<()> {
        let timeout = deadline
            .map(|deadline| deadline.saturating_duration_since(Instant::now()).as_nanos())
            .map(|nanos| nanos.try_into().unwrap_or(wasi::Timestamp::MAX))
            .unwrap_or(wasi::Timestamp::MAX);
        let start = events.list.len();
        let capacity = events.list.capacity() - start;
        let count = unsafe {
            wasi::epoll_wait(
                self.epoll_fd,
                events.list.as_mut_ptr().add(start),
                capacity,
                timeout,
            )
        }
        .map_err(io_err)?;
        unsafe { events.list.set_len(start + count) };

        self.clear_notification();
        self.modify(
            self.notifier.as_fd(),
            Event::readable(crate::NOTIFY_KEY),
            PollMode::Oneshot,
        )
    }

    /// Sends a notification to wake up the current or next wait call.
    pub fn notify(&self) -> io::Result<()> {
        let bytes = 1u64.to_ne_bytes();
        match (&self.notifier).write(&bytes) {
            Ok(_) => Ok(()),
            Err(err) if err.kind() == io::ErrorKind::WouldBlock => {
                self.clear_notification();
                (&self.notifier).write_all(&bytes)
            }
            Err(err) => Err(err),
        }
    }

    fn clear_notification(&self) {
        let mut bytes = [0u8; 8];
        let _ = (&self.notifier).read(&mut bytes);
    }
}

impl AsRawFd for Poller {
    fn as_raw_fd(&self) -> RawFd {
        self.epoll_fd as RawFd
    }
}

impl AsFd for Poller {
    fn as_fd(&self) -> BorrowedFd<'_> {
        unsafe { BorrowedFd::borrow_raw(self.as_raw_fd()) }
    }
}

impl Drop for Poller {
    fn drop(&mut self) {
        let _ = self.delete(self.notifier.as_fd());
        let _ = unsafe { wasi::fd_close(self.epoll_fd) };
    }
}

fn epoll_flags(interest: &Event, mode: PollMode) -> wasi::EpollType {
    let mut flags = match mode {
        PollMode::Oneshot => wasi::EPOLL_TYPE_EPOLLONESHOT,
        PollMode::Level => 0,
        PollMode::Edge => wasi::EPOLL_TYPE_EPOLLET,
        PollMode::EdgeOneshot => wasi::EPOLL_TYPE_EPOLLET | wasi::EPOLL_TYPE_EPOLLONESHOT,
    };
    if interest.readable {
        flags |= read_flags();
    }
    if interest.writable {
        flags |= write_flags();
    }
    flags
}

fn read_flags() -> wasi::EpollType {
    wasi::EPOLL_TYPE_EPOLLIN
        | wasi::EPOLL_TYPE_EPOLLRDHUP
        | wasi::EPOLL_TYPE_EPOLLHUP
        | wasi::EPOLL_TYPE_EPOLLERR
        | wasi::EPOLL_TYPE_EPOLLPRI
}

fn write_flags() -> wasi::EpollType {
    wasi::EPOLL_TYPE_EPOLLOUT | wasi::EPOLL_TYPE_EPOLLHUP | wasi::EPOLL_TYPE_EPOLLERR
}

/// A list of reported I/O events.
pub struct Events {
    list: Vec<wasi::EpollEvent>,
}

unsafe impl Send for Events {}

impl Events {
    /// Creates an empty list.
    pub fn with_capacity(cap: usize) -> Events {
        Events {
            list: Vec::with_capacity(cap),
        }
    }

    /// Iterates over I/O events.
    pub fn iter(&self) -> impl Iterator<Item = Event> + '_ {
        self.list.iter().map(|ev| Event {
            key: ev.data.data2 as usize,
            readable: ev.events & read_flags() != 0,
            writable: ev.events & write_flags() != 0,
            extra: EventExtra { flags: ev.events },
        })
    }

    /// Clears the list.
    pub fn clear(&mut self) {
        self.list.clear();
    }

    /// Returns the list capacity.
    pub fn capacity(&self) -> usize {
        self.list.capacity()
    }
}

/// Extra information about an event.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct EventExtra {
    flags: wasi::EpollType,
}

impl EventExtra {
    /// Creates empty event information.
    pub const fn empty() -> EventExtra {
        EventExtra { flags: 0 }
    }

    /// Sets the hang-up flag.
    pub fn set_hup(&mut self, active: bool) {
        set_flag(&mut self.flags, wasi::EPOLL_TYPE_EPOLLHUP, active);
    }

    /// Sets the priority flag.
    pub fn set_pri(&mut self, active: bool) {
        set_flag(&mut self.flags, wasi::EPOLL_TYPE_EPOLLPRI, active);
    }

    /// Reports whether the event is a hang-up.
    pub fn is_hup(&self) -> bool {
        self.flags & wasi::EPOLL_TYPE_EPOLLHUP != 0
    }

    /// Reports whether the event is priority data.
    pub fn is_pri(&self) -> bool {
        self.flags & wasi::EPOLL_TYPE_EPOLLPRI != 0
    }

    pub fn is_connect_failed(&self) -> Option<bool> {
        Some(
            self.flags & wasi::EPOLL_TYPE_EPOLLERR != 0
                && self.flags & wasi::EPOLL_TYPE_EPOLLHUP != 0,
        )
    }

    pub fn is_err(&self) -> Option<bool> {
        Some(self.flags & wasi::EPOLL_TYPE_EPOLLERR != 0)
    }
}

fn set_flag(flags: &mut wasi::EpollType, flag: wasi::EpollType, active: bool) {
    if active {
        *flags |= flag;
    } else {
        *flags &= !flag;
    }
}

fn io_err(errno: wasi::x::Errno) -> io::Error {
    io::Error::from_raw_os_error(errno.raw() as i32)
}
