//! After a skill directory is written, repair the executable bit on its
//! launcher and on any engine binary already staged under
//! `scripts/bin/<os>-<arch>/`. Not part of the JS; see the crate docs.
//!
//! Fork: the engine binary is never downloaded. Upstream fetched it from
//! the `engine-v<version>` GitHub Release here; the fork build ships it next to
//! the launcher, which verifies it against `scripts/engine-checksums.txt`.

use impeccable_common::Io;

use crate::providers::Sys;
use crate::util::{self, jsp};

/// The `<os>-<arch>` tag the launcher computes (`darwin|linux|windows` x
/// `arm64|x64`); `None` on a platform without a release asset.
pub fn platform_tag() -> Option<(&'static str, &'static str)> {
    let os = if cfg!(target_os = "macos") {
        "darwin"
    } else if cfg!(target_os = "linux") {
        "linux"
    } else if cfg!(target_os = "windows") {
        "windows"
    } else {
        return None;
    };
    let arch = if cfg!(target_arch = "aarch64") {
        "arm64"
    } else if cfg!(target_arch = "x86_64") {
        "x64"
    } else {
        return None;
    };
    Some((os, arch))
}

/// Where the binary for `(os, arch)` lives inside a skill directory.
pub fn binary_path(skill_dir: &str, os: &str, arch: &str) -> String {
    let name = if os == "windows" { "impeccable.exe" } else { "impeccable" };
    jsp::join(&[skill_dir, "scripts", "bin", &format!("{os}-{arch}"), name])
}

/// Belt and suspenders for the executable bit: chmod +x the launcher
/// (`scripts/impeccable`) and every staged engine binary
/// (`scripts/bin/**/impeccable*`) inside a skill dir. Zip extraction and the
/// dir copy preserve modes themselves, but any channel that loses them (a
/// zip with no unix modes, a mode-dropping copier) would otherwise turn every
/// hook and Setup call into "Permission denied". No-op off unix and for
/// missing paths.
pub fn ensure_executable_scripts(skill_dir: &str) {
    let launcher = jsp::join(&[skill_dir, "scripts", "impeccable"]);
    if util::exists(&launcher) {
        let _ = util::set_executable(&launcher);
    }
    let bin_root = jsp::join(&[skill_dir, "scripts", "bin"]);
    for tag in util::read_dir_names(&bin_root).unwrap_or_default() {
        let dir = jsp::join(&[&bin_root, &tag]);
        if !util::is_dir(&dir) {
            continue;
        }
        for name in util::read_dir_names(&dir).unwrap_or_default() {
            if name.starts_with("impeccable") {
                let _ = util::set_executable(&jsp::join(&[&dir, &name]));
            }
        }
    }
}

/// Repairs the executable bit on the launcher and any binaries already
/// present in `skill_dirs`. Fork: installs no engine binary and touches
/// no network; the launcher stops with a message when the binary is missing.
pub fn install_engine_binaries(_sys: &Sys, _io: &mut Io, skill_dirs: &[String]) {
    for skill_dir in skill_dirs {
        ensure_executable_scripts(skill_dir);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn binary_path_matches_launcher() {
        // The sibling binary path is joined with the host's path semantics
        // (backslashes on Windows); only the asset name is platform-keyed.
        assert_eq!(
            binary_path("/s", "linux", "x64"),
            jsp::join(&["/s", "scripts", "bin", "linux-x64", "impeccable"])
        );
        assert_eq!(
            binary_path("/s", "windows", "arm64"),
            jsp::join(&["/s", "scripts", "bin", "windows-arm64", "impeccable.exe"])
        );
    }

    #[test]
    fn install_never_fetches_a_binary() {
        let Some((os, arch)) = platform_tag() else { return };
        let dir = std::env::temp_dir().join(format!("impeccable-fork-no-fetch-{}", std::process::id()));
        let skill_dir = dir.to_string_lossy().into_owned();
        std::fs::create_dir_all(dir.join("scripts")).unwrap();
        std::fs::write(dir.join("scripts/VERSION"), "9.9.9\n").unwrap();
        std::fs::write(dir.join("scripts/engine-checksums.txt"), "9.9.9 impeccable-linux-x64 abc\n").unwrap();
        let env: util::Env = Default::default();
        let (mut io, captured) = Io::captured("", dir.clone(), env.clone());
        install_engine_binaries(&Sys::new(env, skill_dir.clone()), &mut io, &[skill_dir.clone()]);
        assert!(captured.stdout.borrow().is_empty());
        assert!(captured.stderr.borrow().is_empty());
        assert!(!util::exists(&binary_path(&skill_dir, os, arch)));
        let _ = std::fs::remove_dir_all(&dir);
    }
}
