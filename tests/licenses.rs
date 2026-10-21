use serde_json::Value;
use std::{fs, process::Command};

#[test]
fn unicode_notice_is_retrievable_without_account_state() {
    let home = std::env::temp_dir().join(format!("omamail-license-test-{}", std::process::id()));
    fs::create_dir(&home).unwrap();
    let expected = include_str!("../data/unicode/LICENSE.txt");
    for arguments in [vec!["licenses"], vec!["licenses", "--json"]] {
        let output = Command::new(env!("CARGO_BIN_EXE_omamail"))
            .args(&arguments)
            .current_dir(&home)
            .env("HOME", &home)
            .env("XDG_CONFIG_HOME", &home)
            .env("XDG_DATA_HOME", &home)
            .env("XDG_CACHE_HOME", &home)
            .env("XDG_STATE_HOME", &home)
            .output()
            .unwrap();
        assert!(output.status.success(), "{output:?}");
        assert!(output.stderr.is_empty());
        let notice = if arguments.len() == 1 {
            String::from_utf8(output.stdout).unwrap()
        } else {
            serde_json::from_slice::<Value>(&output.stdout).unwrap()["unicode"]
                .as_str()
                .unwrap()
                .to_owned()
        };
        assert_eq!(notice, expected);
        assert!(notice.contains("COPYRIGHT AND PERMISSION NOTICE"));
        assert!(fs::read_dir(&home).unwrap().next().is_none());
    }
    fs::remove_dir(home).unwrap();
}
