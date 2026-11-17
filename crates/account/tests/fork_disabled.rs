//! Fork: the account service is switched off in the library itself, not
//! only behind the CLI. `login` called directly must fail with
//! the disabled message before it sends a single request, even with a live
//! issuer on 127.0.0.1 configured.
mod support;
use impeccable_account::{login, OEG_DISABLED_MSG};
use std::time::Duration;
use support::fake::Fake;

#[test]
fn login_is_refused_without_a_request_even_with_a_live_issuer() {
    let fake = Fake::start();
    let env = fake.env("fork-disabled-login");
    let mut opened = Vec::new();
    let result = login(&env, &mut |url| opened.push(url.to_string()), Duration::from_secs(5));
    let err = match result {
        Ok(_) => panic!("login succeeded although the account service is switched off"),
        Err(e) => e,
    };
    assert!(err.contains(OEG_DISABLED_MSG), "{err}");
    assert!(opened.is_empty(), "a browser was asked to open {opened:?}");
    // Give a request that might still be in flight time to be counted.
    std::thread::sleep(Duration::from_millis(200));
    let hits = fake.record.lock().unwrap().hits.clone();
    assert!(hits.is_empty(), "the issuer was asked: {hits:?}");
}
