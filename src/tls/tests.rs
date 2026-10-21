use super::*;

#[test]
fn the_system_store_is_added_to_the_bundled_list_and_bad_entries_are_skipped() {
    let bundled = webpki_roots::TLS_SERVER_ROOTS.len();
    assert_eq!(roots_with(Vec::new()).len(), bundled);

    // A private authority, as a system store carries it. Self-signed with
    // openssl at test time so nothing in the tree is a certificate.
    let directory = tempdir();
    let certificate_path = directory.join("ca.pem");
    let generated = std::process::Command::new("openssl")
        .args(["req", "-x509", "-newkey", "rsa:2048", "-nodes", "-keyout"])
        .arg(directory.join("key.pem"))
        .arg("-out")
        .arg(&certificate_path)
        .args(["-days", "1", "-subj", "/CN=private-ca"])
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .status()
        .unwrap()
        .success();
    assert!(generated);
    let private = rustls_native_certs::load_certs_from_paths(Some(&certificate_path), None).certs;
    assert_eq!(private.len(), 1);
    assert_eq!(roots_with(private.clone()).len(), bundled + 1);

    // Bytes that are not a certificate cost nothing but themselves.
    let mut mixed = private;
    mixed.push(CertificateDer::from(vec![0u8; 8]));
    assert_eq!(roots_with(mixed).len(), bundled + 1);
    std::fs::remove_dir_all(directory).unwrap();
}

fn tempdir() -> std::path::PathBuf {
    let directory = std::env::temp_dir().join(format!("omamail-tls-{}", std::process::id()));
    std::fs::create_dir_all(&directory).unwrap();
    directory
}
