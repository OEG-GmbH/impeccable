//! Fork: hook state and audit writes bound to directory descriptors.
//!
//! A write target is a trusted base directory plus plain path components.
//! The base is opened once; every component below it is opened (created when
//! missing) with `openat(O_DIRECTORY | O_NOFOLLOW)`, and the file itself is
//! created or opened relative to the last descriptor with `O_NOFOLLOW`. A
//! symlink anywhere below the base, planted before or during the write, makes
//! the write fail instead of leaving the base. `..`, `.` and empty components
//! are refused.
//!
//! Off unix (Windows builds are not shipped by the fork) the same API writes
//! by path after a `symlink_metadata` check of every component.

use std::io;

fn invalid() -> io::Error {
    io::Error::from(io::ErrorKind::InvalidInput)
}

/// Splits a relative path into plain components. `None` when a component is
/// `..` or the path is empty; `.` and empty segments are skipped.
pub fn components(rel: &str) -> Option<Vec<String>> {
    let mut out = Vec::new();
    for part in rel.split(|c| c == '/' || (cfg!(windows) && c == '\\')) {
        match part {
            "" | "." => continue,
            ".." => return None,
            p => out.push(p.to_string()),
        }
    }
    if out.is_empty() {
        None
    } else {
        Some(out)
    }
}

fn check_component(c: &str) -> io::Result<()> {
    if c.is_empty() || c == "." || c == ".." || c.contains('/') || c.contains('\0') || (cfg!(windows) && c.contains('\\')) {
        Err(invalid())
    } else {
        Ok(())
    }
}

#[cfg(unix)]
mod imp {
    use super::check_component;
    use std::ffi::CString;
    use std::io::{self, Write};
    use std::os::fd::{AsRawFd, FromRawFd, OwnedFd};

    fn cstr(s: &str) -> io::Result<CString> {
        CString::new(s).map_err(|_| super::invalid())
    }

    fn fd_or_err(fd: libc::c_int) -> io::Result<OwnedFd> {
        if fd < 0 {
            Err(io::Error::last_os_error())
        } else {
            // SAFETY: a fresh descriptor returned by open/openat, owned here.
            Ok(unsafe { OwnedFd::from_raw_fd(fd) })
        }
    }

    /// Opens the trusted base directory (symlinks in the base path itself
    /// are the caller's choice and are followed).
    fn open_base(base: &str) -> io::Result<OwnedFd> {
        let p = cstr(base)?;
        // SAFETY: valid NUL-terminated path.
        fd_or_err(unsafe { libc::open(p.as_ptr(), libc::O_RDONLY | libc::O_DIRECTORY | libc::O_CLOEXEC) })
    }

    fn open_child_dir(dir: &OwnedFd, name: &str, create: bool) -> io::Result<OwnedFd> {
        check_component(name)?;
        let c = cstr(name)?;
        if create {
            // SAFETY: valid descriptor and NUL-terminated name.
            if unsafe { libc::mkdirat(dir.as_raw_fd(), c.as_ptr(), 0o777) } < 0 {
                let e = io::Error::last_os_error();
                if e.kind() != io::ErrorKind::AlreadyExists {
                    return Err(e);
                }
            }
        }
        // SAFETY: valid descriptor and NUL-terminated name.
        fd_or_err(unsafe {
            libc::openat(dir.as_raw_fd(), c.as_ptr(), libc::O_RDONLY | libc::O_DIRECTORY | libc::O_NOFOLLOW | libc::O_CLOEXEC)
        })
    }

    pub fn open_dir(base: &str, dirs: &[String], create: bool) -> io::Result<OwnedFd> {
        let mut fd = open_base(base)?;
        for d in dirs {
            fd = open_child_dir(&fd, d, create)?;
        }
        Ok(fd)
    }

    fn open_file(dir: &OwnedFd, name: &str, flags: libc::c_int) -> io::Result<std::fs::File> {
        check_component(name)?;
        let c = cstr(name)?;
        // SAFETY: valid descriptor and NUL-terminated name; mode as for std::fs.
        let fd = fd_or_err(unsafe {
            libc::openat(dir.as_raw_fd(), c.as_ptr(), flags | libc::O_NOFOLLOW | libc::O_CLOEXEC, 0o666 as libc::c_uint)
        })?;
        Ok(std::fs::File::from(fd))
    }

    pub fn replace(dir: &OwnedFd, name: &str, bytes: &[u8]) -> io::Result<()> {
        let nanos = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.as_nanos()).unwrap_or(0);
        let tmp = format!(".{name}.tmp-{}-{nanos}", std::process::id());
        let written = open_file(dir, &tmp, libc::O_WRONLY | libc::O_CREAT | libc::O_EXCL)
            .and_then(|mut f| f.write_all(bytes).and_then(|_| f.sync_all()));
        let (t, n) = (cstr(&tmp)?, cstr(name)?);
        let renamed = written.and_then(|_| {
            // SAFETY: valid descriptors and NUL-terminated names. renameat
            // replaces a symlink at `name` itself, never its target.
            if unsafe { libc::renameat(dir.as_raw_fd(), t.as_ptr(), dir.as_raw_fd(), n.as_ptr()) } < 0 {
                Err(io::Error::last_os_error())
            } else {
                Ok(())
            }
        });
        if renamed.is_err() {
            // SAFETY: as above; a failed unlink of our own temp file is harmless.
            unsafe { libc::unlinkat(dir.as_raw_fd(), t.as_ptr(), 0) };
        }
        renamed
    }

    pub fn append(dir: &OwnedFd, name: &str, bytes: &[u8]) -> io::Result<()> {
        open_file(dir, name, libc::O_WRONLY | libc::O_CREAT | libc::O_APPEND)?.write_all(bytes)
    }
}

#[cfg(not(unix))]
mod imp {
    use super::check_component;
    use std::io::{self, Write};
    use std::path::PathBuf;

    pub struct Dir(PathBuf);

    fn not_link(p: &std::path::Path) -> io::Result<()> {
        match std::fs::symlink_metadata(p) {
            Ok(m) if m.file_type().is_symlink() => Err(io::Error::from(io::ErrorKind::InvalidInput)),
            Ok(_) => Ok(()),
            Err(e) if e.kind() == io::ErrorKind::NotFound => Ok(()),
            Err(e) => Err(e),
        }
    }

    pub fn open_dir(base: &str, dirs: &[String], create: bool) -> io::Result<Dir> {
        let mut p = PathBuf::from(base);
        for d in dirs {
            check_component(d)?;
            p.push(d);
            not_link(&p)?;
            if create && !p.exists() {
                std::fs::create_dir(&p)?;
            }
        }
        Ok(Dir(p))
    }

    pub fn replace(dir: &Dir, name: &str, bytes: &[u8]) -> io::Result<()> {
        check_component(name)?;
        let target = dir.0.join(name);
        not_link(&target)?;
        let tmp = dir.0.join(format!(".{name}.tmp-{}", std::process::id()));
        let r = std::fs::OpenOptions::new().write(true).create_new(true).open(&tmp).and_then(|mut f| f.write_all(bytes)).and_then(|_| std::fs::rename(&tmp, &target));
        if r.is_err() {
            let _ = std::fs::remove_file(&tmp);
        }
        r
    }

    pub fn append(dir: &Dir, name: &str, bytes: &[u8]) -> io::Result<()> {
        check_component(name)?;
        let target = dir.0.join(name);
        not_link(&target)?;
        std::fs::OpenOptions::new().create(true).append(true).open(&target)?.write_all(bytes)
    }
}

/// Replaces `<base>/<dirs…>/<name>` with `bytes` (temp file plus rename in
/// the same directory), creating missing directories. False on any failure,
/// including a symlink below `base`.
pub fn replace_in(base: &str, dirs: &[String], name: &str, bytes: &[u8]) -> bool {
    imp::open_dir(base, dirs, true).and_then(|d| imp::replace(&d, name, bytes)).is_ok()
}

/// Appends `bytes` to `<base>/<dirs…>/<name>`, creating it and missing
/// directories. False on any failure, including a symlink below `base`.
pub fn append_in(base: &str, dirs: &[String], name: &str, bytes: &[u8]) -> bool {
    imp::open_dir(base, dirs, true).and_then(|d| imp::append(&d, name, bytes)).is_ok()
}
