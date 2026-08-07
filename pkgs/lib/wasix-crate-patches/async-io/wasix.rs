// SPDX-License-Identifier: MIT OR Apache-2.0

use polling::{Event, Poller};

use std::fmt;
use std::io::Result;
use std::os::wasi::io::{AsRawFd, BorrowedFd, RawFd};

/// The raw registration into the reactor.
#[doc(hidden)]
pub struct Registration {
    /// Raw WASIX file descriptor.
    ///
    /// # Invariant
    ///
    /// This describes a valid file descriptor that remains open while this
    /// object is alive.
    raw: RawFd,
}

impl fmt::Debug for Registration {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        fmt::Debug::fmt(&self.raw, f)
    }
}

impl Registration {
    /// Creates a registration for a borrowed descriptor.
    ///
    /// # Safety
    ///
    /// The descriptor must remain valid while this object is alive.
    pub(crate) unsafe fn new(f: BorrowedFd<'_>) -> Self {
        Self { raw: f.as_raw_fd() }
    }

    #[inline]
    pub(crate) fn add(&self, poller: &Poller, token: usize) -> Result<()> {
        unsafe { poller.add(self.raw, Event::none(token)) }
    }

    #[inline]
    pub(crate) fn modify(&self, poller: &Poller, interest: Event) -> Result<()> {
        let fd = unsafe { BorrowedFd::borrow_raw(self.raw) };
        poller.modify(fd, interest)
    }

    #[inline]
    pub(crate) fn delete(&self, poller: &Poller) -> Result<()> {
        let fd = unsafe { BorrowedFd::borrow_raw(self.raw) };
        poller.delete(fd)
    }
}
