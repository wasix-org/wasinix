//! Updating the repo's pins: what a target is, how each backend bumps one,
//! and the ChangeSet everything renders from.

pub mod backends;
pub mod changeset;
pub mod cratepins;
pub mod drive;
pub mod history;
pub mod managed;
pub mod rels;
pub mod retention;
pub mod select;
pub mod request;
pub mod targets;

pub use request::{Mode, Request, REQUEST_ENV};
