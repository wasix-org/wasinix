use std::io::IsTerminal;

/// All painted output goes to stderr; stdout carries documents, which are
/// never colored, so stderr is the one stream with a color decision.
#[derive(Clone, Copy, PartialEq, Eq)]
pub enum ColorChoice {
    Auto,
    Always,
    Never,
}

static COLOR: std::sync::atomic::AtomicU8 = std::sync::atomic::AtomicU8::new(0);

pub fn set_color_choice(choice: ColorChoice) {
    let value = match choice {
        ColorChoice::Auto => 0,
        ColorChoice::Always => 1,
        ColorChoice::Never => 2,
    };
    COLOR.store(value, std::sync::atomic::Ordering::Relaxed);
}

pub fn interactive() -> bool {
    std::io::stderr().is_terminal() && !crate::support::env::term_is_dumb()
}

pub fn color_enabled() -> bool {
    match COLOR.load(std::sync::atomic::Ordering::Relaxed) {
        1 => true,
        2 => false,
        _ => {
            if crate::support::env::no_color() {
                return false;
            }
            crate::support::env::clicolor_force() || interactive()
        }
    }
}

fn paint(code: &str, text: impl std::fmt::Display) -> String {
    if color_enabled() {
        format!("\u{1b}[{code}m{text}\u{1b}[0m")
    } else {
        text.to_string()
    }
}

pub fn command(text: impl std::fmt::Display) -> String {
    paint("1;36", text)
}

pub fn error(text: impl std::fmt::Display) -> String {
    paint("1;31", text)
}
