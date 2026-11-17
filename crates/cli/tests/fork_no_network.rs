//! Fork (review F5): behaviour tests for the network switches.
//!
//! Every service URL override points at one local TCP listener that counts
//! each connection attempt, and a full sign-in (every feature scope, an
//! expired access token, so a refresh would be due) sits in the credential
//! store. The engine is then run for the scan, context, roll, account,
//! upload, help and image verbs. The listener must see no connection, also
//! after a pause for any detached worker (setup report, taste refresh, Pro
//! refresh) the runs could have spawned. `detect` runs with IMPECCABLE_PRO=on
//! and the sign-in, the case in which upstream Pro dispatch renews its lease.
//!
//! Checked against the fault: with the account build switch, the roll switch or
//! the telemetry switch set back to false, this test fails.
#![cfg(unix)]

use impeccable_account::config::Account;
use impeccable_account::oauth::{CRITIQUES_SCOPE, DESIGN_SCOPE, HEALTH_SCOPE, TASTE_READ_SCOPE};
use impeccable_account::store::{Backend, Secret, State, Store};
use std::collections::HashMap;
use std::net::{TcpListener, TcpStream};
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::Arc;
use std::time::Duration;

/// A listener that counts every accepted connection and answers nothing.
fn counting_listener() -> (String, Arc<AtomicUsize>) {
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let base = format!("http://127.0.0.1:{}", listener.local_addr().unwrap().port());
    let hits = Arc::new(AtomicUsize::new(0));
    let counter = hits.clone();
    std::thread::spawn(move || {
        for stream in listener.incoming() {
            counter.fetch_add(1, Ordering::SeqCst);
            drop(stream);
        }
    });
    (base, hits)
}

fn wait_for(hits: &AtomicUsize, n: usize) -> usize {
    for _ in 0..50 {
        if hits.load(Ordering::SeqCst) >= n {
            break;
        }
        std::thread::sleep(Duration::from_millis(20));
    }
    hits.load(Ordering::SeqCst)
}

fn temp_dir(name: &str) -> PathBuf {
    let dir = std::env::temp_dir().join(format!("impeccable-fork-net-{name}-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();
    dir
}

fn env_for(home: &Path, base: &str) -> HashMap<String, String> {
    let home_s = home.to_string_lossy().into_owned();
    let skill = Path::new(env!("CARGO_MANIFEST_DIR")).join("../../skill").to_string_lossy().into_owned();
    HashMap::from([
        ("HOME".to_string(), home_s.clone()),
        ("USERPROFILE".to_string(), home_s.clone()),
        ("IMPECCABLE_HOME".to_string(), home_s),
        ("IMPECCABLE_CREDENTIAL_STORE".to_string(), "file".to_string()),
        ("IMPECCABLE_SKILL_DIR".to_string(), skill),
        ("IMPECCABLE_SEED_SALT".to_string(), "test-salt".to_string()),
        ("IMPECCABLE_API_TIMEOUT".to_string(), "1500".to_string()),
        // Every override the upstream engine reads for its services.
        ("IMPECCABLE_ACCOUNT_URL".to_string(), base.to_string()),
        ("IMPECCABLE_API_URL".to_string(), format!("{base}/api")),
        ("IMPECCABLE_UPDATE_HOST".to_string(), base.to_string()),
        ("IMPECCABLE_CARD_BASE".to_string(), format!("{base}/cards")),
        ("IMPECCABLE_DOWNLOAD_BASE".to_string(), base.to_string()),
        ("IMPECCABLE_PRO".to_string(), "on".to_string()),
        ("OPENAI_API_KEY".to_string(), "test-not-a-key".to_string()),
        ("OPENAI_BASE_URL".to_string(), format!("{base}/v1")),
    ])
}

/// A signed-in state with every feature scope and an expired access token.
fn sign_in(env: &HashMap<String, String>, base: &str) {
    let account = Account::from_env(env).unwrap();
    let store = Store::new(&account);
    let state = State {
        foundations: true,
        taste: true,
        schema: 1,
        scopes: [HEALTH_SCOPE, CRITIQUES_SCOPE, DESIGN_SCOPE, TASTE_READ_SCOPE, "setup:write", "worlds:read"].iter().map(|s| s.to_string()).collect(),
        issuer: account.issuer.clone(),
        generation: 1,
        signed_in: true,
        backend: Backend::File,
        token_endpoint: format!("{base}/oauth/token"),
        revocation_endpoint: Some(format!("{base}/oauth/revoke")),
        login: 1,
        signed_out_at: 0,
    };
    let secret = Secret { generation: 1, refresh_token: "test-refresh".into(), access_token: "test-access".into(), access_expires_at: 1 };
    let lock = store.lock().unwrap();
    store.save(&lock, &state, &secret).unwrap();
    assert!(store.state().is_some_and(|s| s.signed_in), "the test sign-in must be readable");
}

fn run(env: &HashMap<String, String>, cwd: &Path, args: &[&str]) -> (i32, String) {
    let mut cmd = Command::new(env!("CARGO_BIN_EXE_impeccable"));
    cmd.args(args).current_dir(cwd).env_clear().envs(env).stdin(Stdio::null());
    if let Ok(path) = std::env::var("PATH") {
        cmd.env("PATH", path);
    }
    let out = cmd.output().unwrap();
    let text = format!("{}{}", String::from_utf8_lossy(&out.stdout), String::from_utf8_lossy(&out.stderr));
    (out.status.code().unwrap_or(-1), text)
}

#[test]
fn no_verb_reaches_a_service_even_with_overrides_and_a_sign_in() {
    let (base, hits) = counting_listener();
    // Control: the listener counts a real connection.
    drop(TcpStream::connect(base.trim_start_matches("http://")).unwrap());
    assert_eq!(wait_for(&hits, 1), 1, "the counting listener must see a connection");
    hits.store(0, Ordering::SeqCst);

    let home = temp_dir("all");
    let env = env_for(&home, &base);
    sign_in(&env, &base);
    let project = home.join("project");
    std::fs::create_dir_all(&project).unwrap();
    std::fs::write(project.join("PRODUCT.md"), "# Product\n\n## Users\nTeam.\n\n## Purpose\nProbe.\n").unwrap();
    std::fs::write(project.join("index.html"), "<!doctype html><h1 style=\"color:#aaa;background:#bbb\">Hi</h1>").unwrap();

    // Open verbs: they work, and stay local.
    for args in [
        vec!["detect", "index.html"],
        vec!["context"],
        vec!["concept-seed", "--scope", "direction"],
        vec!["telemetry", "status"],
        vec!["help"],
    ] {
        let (code, text) = run(&env, &project, &args);
        assert!(code == 0 || (args[0] == "detect" && code == 2), "{args:?} exit {code}: {text}");
    }
    // The roll never asks the service: without a local catalog it is degraded.
    let (_, roll) = run(&env, &project, &["concept-seed", "--scope", "direction"]);
    assert!(roll.contains("source: degraded"), "{roll}");
    // Telemetry reads as off whatever the environment says.
    let (_, status) = run(&env, &project, &["telemetry", "status"]);
    assert!(status.contains("telemetry: off"), "{status}");

    // Switched-off verbs refuse with the fork's message.
    for args in [
        vec!["login", "--no-browser"],
        vec!["logout"],
        vec!["whoami"],
        vec!["status"],
        vec!["health"],
        vec!["critiques", "status"],
        vec!["world", "kinpaku"],
        vec!["taste-refresh"],
        vec!["pro-refresh"],
        vec!["setup-report"],
        vec!["loop", "status"],
        vec!["font-match"],
    ] {
        let (code, text) = run(&env, &project, &args);
        assert_ne!(code, 0, "{args:?}: {text}");
        assert!(text.contains("OEG-Fork"), "{args:?}: {text}");
    }
    // A remote --ref is refused before the image API is asked.
    let (code, text) = run(&env, &project, &["generate-image", "--prompt", "x", "--out", "a.png", "--ref", &format!("{base}/cards/a.png")]);
    assert_ne!(code, 0, "{text}");
    assert!(text.contains("remote images are switched off"), "{text}");

    // Give any detached worker time to run, then count.
    std::thread::sleep(Duration::from_millis(1500));
    assert_eq!(hits.load(Ordering::SeqCst), 0, "a verb or a background worker reached the service");
    let _ = std::fs::remove_dir_all(&home);
}
