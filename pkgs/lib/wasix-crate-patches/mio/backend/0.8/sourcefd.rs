use crate::{event, Interest, Registry, Token};

use std::io;
use std::os::wasi::io::RawFd;

#[derive(Debug)]
pub struct SourceFd<'a>(pub &'a RawFd);

impl<'a> event::Source for SourceFd<'a> {
    fn register(
        &mut self,
        registry: &Registry,
        token: Token,
        interests: Interest,
    ) -> io::Result<()> {
        registry.selector().register(*self.0 as u32, token, interests)
    }

    fn reregister(
        &mut self,
        registry: &Registry,
        token: Token,
        interests: Interest,
    ) -> io::Result<()> {
        registry.selector().reregister(*self.0 as u32, token, interests)
    }

    fn deregister(&mut self, registry: &Registry) -> io::Result<()> {
        registry.selector().deregister(*self.0 as u32)
    }
}
