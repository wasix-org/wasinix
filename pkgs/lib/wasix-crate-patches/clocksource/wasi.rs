fn read_clock(clock: libc::clockid_t) -> libc::timespec {
    let mut ts = libc::timespec {
        tv_sec: 0,
        tv_nsec: 0,
    };
    unsafe {
        libc::clock_gettime(clock, &mut ts);
    }
    ts
}

pub mod monotonic {
    pub fn coarse() -> crate::coarse::Instant {
        let ts = super::read_clock(libc::CLOCK_MONOTONIC);
        crate::coarse::Instant {
            secs: ts.tv_sec as u32,
        }
    }

    pub fn precise() -> crate::precise::Instant {
        let ts = super::read_clock(libc::CLOCK_MONOTONIC);
        let now = (ts.tv_sec as u64)
            .wrapping_mul(1_000_000_000)
            .wrapping_add(ts.tv_nsec as u64);
        crate::precise::Instant { ns: now }
    }
}

pub mod realtime {
    pub fn coarse() -> crate::coarse::UnixInstant {
        let ts = super::read_clock(libc::CLOCK_REALTIME);
        crate::coarse::UnixInstant {
            secs: ts.tv_sec as u32,
        }
    }

    pub fn precise() -> crate::precise::UnixInstant {
        let ts = super::read_clock(libc::CLOCK_REALTIME);
        let now = (ts.tv_sec as u64)
            .wrapping_mul(1_000_000_000)
            .wrapping_add(ts.tv_nsec as u64);
        crate::precise::UnixInstant { ns: now }
    }
}
