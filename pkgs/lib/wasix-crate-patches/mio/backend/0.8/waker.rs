mod eventfd {
    use std::io;
    use crate::sys::Selector;
    use crate::{Interest, Token};
    use std::fs::File;

    use std::io::{Write, Read};
    use std::os::wasi::io::FromRawFd;
    use std::convert::TryInto;

    #[cfg(target_vendor = "wasmer")]
    use ::wasix as wasi;

    #[derive(Debug)]
    pub struct Waker {
        fd: File,
    }

    impl Waker {
        pub fn new(selector: &Selector, token: Token) -> io::Result<Waker> {
            let fd = unsafe {
                wasi::fd_event(0, 0)
                    .map_err(|errno| io::Error::from_raw_os_error(errno.raw() as i32))?
            };

            let fdstat = unsafe {
                wasi::fd_fdstat_get(fd)
                    .map_err(|errno| io::Error::from_raw_os_error(errno.raw() as i32))?
            };
        
            let mut flags = fdstat.fs_flags;
            flags |= wasi::FDFLAGS_NONBLOCK;
            unsafe {
                wasi::fd_fdstat_set_flags(fd, flags)
                    .map_err(|errno| io::Error::from_raw_os_error(errno.raw() as i32))?
            }

            let file = unsafe { File::from_raw_fd(fd.try_into().unwrap()) };
            selector
                .register(fd, token, Interest::READABLE)
                .map(|()| Waker { fd: file })
        }

        pub fn wake(&self) -> io::Result<()> {
            let buf: [u8; 8] = 1u64.to_ne_bytes();
            match (&self.fd).write(&buf) {
                Ok(_) => Ok(()),
                Err(ref err) if err.kind() == io::ErrorKind::WouldBlock => {
                    // Writing only blocks if the counter is going to overflow.
                    // So we'll reset the counter to 0 and wake it again.
                    self.reset()?;
                    self.wake()
                }
                Err(err) => Err(err),
            }
        }

        /// Reset the eventfd object, only need to call this if `wake` fails.
        fn reset(&self) -> io::Result<()> {
            let mut buf: [u8; 8] = 0u64.to_ne_bytes();
            match (&self.fd).read(&mut buf) {
                Ok(_) => Ok(()),
                // If the `Waker` hasn't been awoken yet this will return a
                // `WouldBlock` error which we can safely ignore.
                Err(ref err) if err.kind() == io::ErrorKind::WouldBlock => Ok(()),
                Err(err) => Err(err),
            }
        }
    }
}

pub use self::eventfd::Waker;
