use std::process::{ExitCode, ExitStatus};

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, PartialOrd, Ord)]
pub struct CommandStatus(u8);

impl CommandStatus {
    pub const SUCCESS: CommandStatus = CommandStatus(0);
    pub const FAILURE: CommandStatus = CommandStatus(1);
    pub const REQUEST_ERROR: CommandStatus = CommandStatus(2);
    pub const NOT_FOUND: CommandStatus = CommandStatus(3);

    pub const fn from_code(code: u8) -> CommandStatus {
        CommandStatus(code)
    }

    pub fn from_exit(status: ExitStatus) -> CommandStatus {
        status
            .code()
            .and_then(|code| u8::try_from(code).ok())
            .map(CommandStatus)
            .unwrap_or(CommandStatus::FAILURE)
    }

    pub fn is_success(self) -> bool {
        self == CommandStatus::SUCCESS
    }

    pub fn code(self) -> u8 {
        self.0
    }
}

impl From<CommandStatus> for ExitCode {
    fn from(status: CommandStatus) -> ExitCode {
        ExitCode::from(status.code())
    }
}

/// Signal a whole process group, so killing a runner takes its spawned tree
/// (nix, ssh) down with it instead of orphaning it.
#[cfg(unix)]
pub fn signal_group(pgid: u32, signal: libc::c_int) -> std::io::Result<()> {
    let pgid = libc::pid_t::try_from(pgid)
        .map_err(|_| std::io::Error::other(format!("child pid {pgid} exceeds pid_t")))?;
    // SAFETY: kill only reads its integer arguments. The negative child pid
    // addresses the process group created by the shared spawn path.
    let result = unsafe { libc::kill(-pgid, signal) };
    if result == 0 {
        return Ok(());
    }
    let error = std::io::Error::last_os_error();
    if error.raw_os_error() == Some(libc::ESRCH) {
        Ok(())
    } else {
        Err(error)
    }
}
