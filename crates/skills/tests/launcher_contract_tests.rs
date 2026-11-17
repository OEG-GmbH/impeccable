//! Guards over the two launchers (`skill/scripts/impeccable`,
//! `skill/scripts/impeccable.cmd`) and their shipped copies under `plugin/`.
//! Fork contract: a launcher runs exactly one engine, the binary in
//! `bin/<os>-<arch>/` next to it, and only when its sha256 is listed in
//! `engine-checksums.txt`. There is no IMPECCABLE_BIN, no download, no user
//! cache and no PATH lookup. Before hashing, the sh launcher requires a
//! regular file (no symlink) owned like the launcher, and no group- or
//! other-writable file or directory between the launcher and the binary. The
//! .cmd cannot be executed here (no Windows), so it is pinned at the string
//! level; the sh launcher is also run against stubs.

use sha2::{Digest, Sha256};

fn repo_root() -> String {
    format!("{}/../..", env!("CARGO_MANIFEST_DIR"))
}

fn launcher_dirs() -> [String; 2] {
    let root = repo_root();
    [format!("{root}/skill/scripts"), format!("{root}/plugin/skills/impeccable/scripts")]
}

fn read(path: &str) -> String {
    std::fs::read_to_string(path).unwrap_or_else(|e| panic!("read {path}: {e}"))
}

#[test]
fn shipped_launchers_match_the_source() {
    let [src, plugin] = launcher_dirs();
    for name in ["impeccable", "impeccable.cmd", "engine-checksums.txt"] {
        assert_eq!(
            read(&format!("{src}/{name}")).replace("\r\n", "\n"),
            read(&format!("{plugin}/{name}")).replace("\r\n", "\n"),
            "plugin/skills/impeccable/scripts/{name} differs from skill/scripts/{name}"
        );
    }
}

#[test]
fn launchers_never_download_or_fall_back() {
    for dir in launcher_dirs() {
        for name in ["impeccable", "impeccable.cmd"] {
            let text = read(&format!("{dir}/{name}"));
            for banned in [
                "curl", "wget", "releases/download", "IMPECCABLE_DOWNLOAD_BASE", "where impeccable", "command -v impeccable",
                ".impeccable/bin", "IMPECCABLE_HOME", ".verified", "${IMPECCABLE_BIN", "%IMPECCABLE_BIN%",
            ] {
                assert!(!text.contains(banned), "{dir}/{name} still contains {banned:?}");
            }
            assert!(text.contains("engine-checksums.txt"), "{dir}/{name} does not read the manifest");
            assert!(text.contains("checksum mismatch for"), "{dir}/{name} does not refuse a mismatch");
            assert!(text.contains("no checksum for engine"), "{dir}/{name} does not refuse a missing digest");
        }
    }
}

#[test]
fn cmd_launcher_verifies_with_certutil_and_forwards_the_exit_code() {
    for dir in launcher_dirs() {
        let cmd = read(&format!("{dir}/impeccable.cmd"));
        assert!(cmd.contains("certutil -hashfile"));
        assert!(cmd.contains(r#"set "manifest=%~dp0engine-checksums.txt""#));
        assert!(cmd.contains(r#"set "run=%~dp0bin\windows-%arch%\impeccable.exe""#));
        assert!(cmd.contains(r#"if /I "%PROCESSOR_ARCHITECTURE%"=="ARM64" set "arch=arm64""#));
        assert!(cmd.contains("is not installed: no binary at") && cmd.contains("exit /b 3"), "missing binary: exit 3 with a message");
        for (i, line) in cmd.lines().enumerate() {
            // Bare `exit /b` drops the process exit code when this file is
            // cmd.exe's entry point; cmd.exe expands %var% inside a
            // parenthesized block at parse time.
            assert_ne!(line.trim(), "exit /b", "impeccable.cmd line {}: bare exit /b", i + 1);
            assert!(!line.trim_end().ends_with('('), "impeccable.cmd line {}: multi-line block: {line}", i + 1);
        }
        assert_eq!(cmd.matches("exit /b %errorlevel%").count(), 1, ":run must forward the engine exit code");
    }
}

/// A scratch skill dir holding a copy of the sh launcher, a VERSION, a stub
/// engine at the sibling path and a manifest, every directory mode 0755.
#[cfg(unix)]
struct Scratch {
    dir: std::path::PathBuf,
    launcher: std::path::PathBuf,
    stub: std::path::PathBuf,
}

#[cfg(unix)]
fn chmod(path: &std::path::Path, mode: u32) {
    use std::os::unix::fs::PermissionsExt;
    std::fs::set_permissions(path, std::fs::Permissions::from_mode(mode)).unwrap();
}

#[cfg(unix)]
impl Scratch {
    fn new(tag: &str) -> Scratch {
        let (os, arch) = impeccable_skills::engine_binary::platform_tag().expect("supported platform");
        let dir = std::env::temp_dir().join(format!("impeccable-fork-launcher-{tag}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        let scripts = dir.join("scripts");
        let bin_dir = scripts.join(format!("bin/{os}-{arch}"));
        std::fs::create_dir_all(&bin_dir).unwrap();
        for d in [&scripts, &scripts.join("bin"), &bin_dir] {
            chmod(d, 0o755);
        }
        let launcher = scripts.join("impeccable");
        std::fs::copy(format!("{}/impeccable", launcher_dirs()[0]), &launcher).unwrap();
        chmod(&launcher, 0o755);
        std::fs::write(scripts.join("VERSION"), "9.9.9\n").unwrap();
        let stub = bin_dir.join("impeccable");
        std::fs::write(&stub, "#!/bin/sh\nprintf 'RAN SKILL_DIR=%s ARGS=%s\\n' \"${IMPECCABLE_SKILL_DIR:-UNSET}\" \"$*\"\n").unwrap();
        chmod(&stub, 0o755);
        Scratch { dir, launcher, stub }
    }

    fn list(&self, path: &std::path::Path) {
        let (os, arch) = impeccable_skills::engine_binary::platform_tag().unwrap();
        let digest: String = Sha256::digest(std::fs::read(path).unwrap()).iter().map(|b| format!("{b:02x}")).collect();
        std::fs::write(self.dir.join("scripts/engine-checksums.txt"), format!("# test\n9.9.9 impeccable-{os}-{arch} {digest}\n")).unwrap();
    }

    fn run_env(&self, env: &[(&str, &str)]) -> (i32, String, String) {
        let mut cmd = std::process::Command::new("sh");
        cmd.arg(&self.launcher).arg("context").env_remove("IMPECCABLE_SKILL_DIR").env_remove("IMPECCABLE_BIN");
        for (k, v) in env {
            cmd.env(k, v);
        }
        let out = cmd.output().expect("run launcher");
        (out.status.code().unwrap_or(-1), String::from_utf8_lossy(&out.stdout).into_owned(), String::from_utf8_lossy(&out.stderr).into_owned())
    }

    fn run(&self) -> (i32, String, String) {
        self.run_env(&[])
    }
}

#[cfg(unix)]
impl Drop for Scratch {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.dir);
    }
}

#[cfg(unix)]
#[test]
fn sh_launcher_runs_a_listed_sibling_and_exports_the_skill_dir() {
    let s = Scratch::new("listed");
    s.list(&s.stub);
    let (code, out, err) = s.run();
    assert_eq!(code, 0, "{err}");
    assert!(out.contains("RAN SKILL_DIR=") && !out.contains("SKILL_DIR=UNSET") && out.contains("ARGS=context"), "{out}");
    // The second run hashes again and still runs.
    let (code, out, _) = s.run();
    assert_eq!(code, 0);
    assert!(out.contains("RAN"));
}

#[cfg(unix)]
#[test]
fn sh_launcher_refuses_an_unlisted_or_changed_sibling() {
    let s = Scratch::new("unlisted");
    std::fs::write(s.dir.join("scripts/engine-checksums.txt"), "# nothing listed\n").unwrap();
    let (code, out, err) = s.run();
    assert_eq!(code, 127);
    assert!(!out.contains("RAN"), "{out}");
    assert!(err.contains("no checksum for engine 9.9.9"), "{err}");

    s.list(&s.stub);
    assert_eq!(s.run().0, 0);
    // Tamper after a verified run: the next run hashes again and refuses.
    std::fs::write(&s.stub, "#!/bin/sh\necho RAN-TAMPERED\n").unwrap();
    let (code, out, err) = s.run();
    assert_eq!(code, 127, "{out}");
    assert!(!out.contains("RAN"), "{out}");
    assert!(err.contains("checksum mismatch for"), "{err}");
}

#[cfg(unix)]
#[test]
fn sh_launcher_refuses_a_missing_sibling() {
    let s = Scratch::new("missing");
    s.list(&s.stub);
    std::fs::remove_file(&s.stub).unwrap();
    // Review (git-delivered copies ship launcher-only): a missing binary
    // is "not installed" (exit 3) with the path and what to put there, not
    // the 127 of a refused binary.
    let (code, _, err) = s.run();
    assert_eq!(code, 3, "{err}");
    assert!(err.contains("engine 9.9.9 is not installed: no binary at") && err.contains("downloads nothing"), "{err}");
    assert!(err.contains(&s.stub.to_string_lossy().into_owned()), "{err}");
}

/// Codex review: the manifest lists only linux-x64. On another platform a
/// launcher-only copy has neither binary nor digest, and that is still
/// "not installed" (exit 3), not a checksum refusal. A fake `uname` stands
/// in for darwin-arm64.
#[cfg(unix)]
#[test]
fn sh_launcher_says_not_installed_on_a_platform_without_a_digest() {
    let s = Scratch::new("nodigest");
    std::fs::write(s.dir.join("scripts/engine-checksums.txt"), "9.9.9 impeccable-linux-x64 abc\n").unwrap();
    let fake = s.dir.join("fake-uname");
    std::fs::create_dir_all(&fake).unwrap();
    std::fs::write(fake.join("uname"), "#!/bin/sh\necho 'Darwin arm64'\n").unwrap();
    chmod(&fake.join("uname"), 0o755);
    let path = format!("{}:{}", fake.display(), std::env::var("PATH").unwrap_or_default());
    let (code, out, err) = s.run_env(&[("PATH", &path)]);
    assert_eq!(code, 3, "{err}");
    assert!(!out.contains("RAN"), "{out}");
    assert!(err.contains("is not installed: no binary at") && err.contains("bin/darwin-arm64/impeccable"), "{err}");
    assert!(err.contains("lists no digest for engine 9.9.9 (impeccable-darwin-arm64) yet") && !err.contains("no checksum for engine"), "{err}");
}

/// Review F1/F2 and the second Codex review: IMPECCABLE_BIN is gone, so a
/// listed binary elsewhere, or a forged stamp beside it, is never run.
#[cfg(unix)]
#[test]
fn sh_launcher_ignores_impeccable_bin_and_any_stamp() {
    let s = Scratch::new("envbin");
    s.list(&s.stub);
    let other = s.dir.join("other");
    std::fs::write(&other, "#!/bin/sh\necho RAN-OTHER\n").unwrap();
    chmod(&other, 0o755);
    let (code, out, err) = s.run_env(&[("IMPECCABLE_BIN", other.to_str().unwrap())]);
    assert_eq!(code, 0, "{err}");
    assert!(out.contains("RAN SKILL_DIR=") && !out.contains("RAN-OTHER"), "{out}");
    // Listing the other binary does not make the launcher pick it either.
    s.list(&other);
    let (code, out, _) = s.run_env(&[("IMPECCABLE_BIN", other.to_str().unwrap())]);
    assert_eq!(code, 127, "{out}");
    assert!(!out.contains("RAN"), "{out}");
}

/// Second Codex review: hash and exec open the path twice, so the launcher
/// refuses a binary someone other than its owner could swap in between.
#[cfg(unix)]
#[test]
fn sh_launcher_refuses_a_swappable_binary() {
    use std::os::unix::fs::symlink;
    let (os, arch) = impeccable_skills::engine_binary::platform_tag().unwrap();
    // A symlink in place of the binary, even to a listed file.
    let s = Scratch::new("symlink");
    let real = s.dir.join("real-engine");
    std::fs::rename(&s.stub, &real).unwrap();
    symlink(&real, &s.stub).unwrap();
    s.list(&real);
    let (code, out, err) = s.run();
    assert_eq!(code, 127, "{out}");
    assert!(!out.contains("RAN") && err.contains("symlink"), "{err}");

    // A group- or other-writable binary, or a writable directory on the way.
    for (what, mode_of) in [("binary", "file"), ("bin dir", "bindir"), ("scripts dir", "scripts")] {
        for mode in [0o775u32, 0o757] {
            let s = Scratch::new(&format!("writable-{mode_of}-{mode:o}"));
            s.list(&s.stub);
            let target = match mode_of {
                "file" => s.stub.clone(),
                "bindir" => s.dir.join(format!("scripts/bin/{os}-{arch}")),
                _ => s.dir.join("scripts"),
            };
            chmod(&target, mode);
            let (code, out, err) = s.run();
            assert_eq!(code, 127, "{what} {mode:o}: {out}");
            assert!(!out.contains("RAN") && err.contains("writable by group or others"), "{what} {mode:o}: {err}");
            chmod(&target, 0o755);
            assert_eq!(s.run().0, 0, "{what}: back to 0755 runs again");
        }
    }

    // Review: GNU stat prints mode 0007 as "7", a single digit.
    for mode in [0o007u32, 0o002] {
        let s = Scratch::new(&format!("onedigit-{mode:o}"));
        s.list(&s.stub);
        chmod(&s.stub, mode);
        let (code, out, err) = s.run();
        assert_eq!(code, 127, "{mode:o}: {out}");
        assert!(!out.contains("RAN") && err.contains("writable by group or others"), "{mode:o}: {err}");
    }
}
