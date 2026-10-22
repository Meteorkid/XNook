pub mod files;
pub mod preferences;
pub mod gifs;
pub mod platform;
pub mod updates;
pub mod exit_policy;
pub mod lyrics;
pub mod media;
pub mod media_selection;
pub mod storage;
pub mod windowing;

#[cfg(feature = "desktop")]
mod desktop;
#[cfg(feature = "desktop")]
pub use desktop::run;
