//! Core domain and transaction engine for the Gino native Skills manager.
//!
//! The crate deliberately keeps filesystem truth in the inventory and plan
//! executor. UI state can derive from these public models without becoming a
//! second installation authority.

pub mod agents;
pub mod command;
pub mod comparison;
pub mod discovery;
pub mod error;
pub mod executor;
pub mod git;
pub mod inventory;
pub mod marketplace;
pub mod metadata;
pub mod planner;
pub mod platform;
pub mod protocol;
pub mod source;

pub use command::{equivalent_command, find_command};
pub use error::{GinoError, Result};
pub use metadata::{APP_VERSION, RELEASES_URL};
pub use protocol::{SkillSource, SourceType};
