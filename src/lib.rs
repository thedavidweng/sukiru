//! Core domain and transaction engine for the Gino native Skills manager.
//!
//! The crate deliberately keeps filesystem truth in the inventory and plan
//! executor. UI state can derive from these public models without becoming a
//! second installation authority.

pub mod agents;
pub mod comparison;
pub mod discovery;
pub mod error;
pub mod executor;
pub mod git;
pub mod inventory;
pub mod metadata;
pub mod planner;
pub mod protocol;

pub use error::{GinoError, Result};
