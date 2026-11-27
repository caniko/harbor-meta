use std::{fs, path::Path, process::Command};

use harbor_evidence::cross_arch::{
    ComparisonVerdict, CrossArchReceiptManifest, DEFAULT_STAGING_CLAIM_FILE, FirstMismatch,
    ProofKind, RemoteStagingSpec, acquire_local_staging_claim, cleanup_local_staging_claim,
    compare_arch_outputs, verify_bundle_dir, write_sha256sums,
};

const VALID_TOKEN: &str = "01234567-89ab-cdef-0123-456789abcdef";
const OTHER_TOKEN: &str = "fedcba98-7654-3210-fedc-ba9876543210";

fn cli(dir: &Path) -> Command {
    let mut command = Command::new(env!("CARGO_BIN_EXE_harbor"));
    command.current_dir(dir).args(["dev", "cross-arch"]);
    command
}

#[test]
fn compares_and_records_match_and_divergence() {
    let temp = tempfile::tempdir().unwrap();
    let dir = temp.path();
    for root in ["reference", "candidate"] {
        fs::create_dir(dir.join(root)).unwrap();
        fs::write(dir.join(root).join("artifact"), b"abc").unwrap();
    }
    fs::write(dir.join("Cargo.lock"), b"lock").unwrap();
    let write = cli(dir)
        .args([
            "sums-write",
            "--bundle-dir",
            "reference",
            "--output",
            "reference/SHA256SUMS",
            "artifact",
        ])
        .output()
        .unwrap();
    assert!(write.status.success(), "{write:?}");
    let verify = cli(dir)
        .args([
            "verify-bundle",
            "--bundle-dir",
            "./reference",
            "--sums",
            "reference/SHA256SUMS",
        ])
        .output()
        .unwrap();
    assert!(verify.status.success(), "{verify:?}");
    let compare = |receipt: &str, target: &str| {
        cli(dir)
            .args([
                "compare",
                "--reference-dir",
                "reference",
                "--candidate-dir",
                "candidate",
                "--reference-target",
                "x86_64-unknown-linux-gnu",
                "--candidate-target",
                target,
                "--source-sha",
                "abcdabcdabcdabcdabcdabcdabcdabcdabcdabcd",
                "--lockfile",
                "Cargo.lock=Cargo.lock",
                "--input-sums",
                "reference/SHA256SUMS",
                "--receipt",
                receipt,
                "artifact",
            ])
            .output()
            .unwrap()
    };
    let target = "aarch64-unknown-linux-gnu";
    let matched = compare("receipt.json", target);
    assert!(matched.status.success(), "{matched:?}");
    let original = fs::read(dir.join("receipt.json")).unwrap();
    assert_eq!(original, matched.stdout);
    let receipt: CrossArchReceiptManifest = serde_json::from_slice(&original).unwrap();
    assert_eq!(receipt.comparison.verdict, ComparisonVerdict::Match);
    assert_eq!(receipt.outputs_sha256, receipt.inputs_sha256);
    assert_eq!(receipt.to_canonical_json().unwrap().as_bytes(), original);
    assert!(receipt.lockfile_sha256s.contains_key("Cargo.lock"));
    assert!(
        !compare("invalid.json", "x86_64-unknown-linux-gnu")
            .status
            .success()
    );
    assert!(!dir.join("invalid.json").exists());

    fs::write(dir.join("candidate/artifact"), b"axc").unwrap();
    let clobber = compare("receipt.json", target);
    assert!(!clobber.status.success(), "{clobber:?}");
    assert!(clobber.stdout.is_empty());
    assert_eq!(original, fs::read(dir.join("receipt.json")).unwrap());
    let diverged = compare("diverged.json", target);
    assert!(!diverged.status.success());
    assert_eq!(
        diverged.stdout,
        fs::read(dir.join("diverged.json")).unwrap()
    );
    let receipt: CrossArchReceiptManifest = serde_json::from_slice(&diverged.stdout).unwrap();
    assert_eq!(receipt.comparison.verdict, ComparisonVerdict::Diverged);
    assert_eq!(
        receipt.comparison.files[0].first_mismatch,
        Some(FirstMismatch {
            byte_offset: 1,
            reference_byte: Some(b'b'),
            candidate_byte: Some(b'x'),
            reference_len: 3,
            candidate_len: 3,
        })
    );
}

#[test]
fn rejects_tampered_missing_and_unexpected_bundle_members() {
    let temp = tempfile::tempdir().unwrap();
    let dir = temp.path();
    let sums = dir.join("SHA256SUMS");
    let a = dir.join("a");
    fs::write(&a, b"a").unwrap();
    let expected = write_sha256sums(dir, &["a"], &sums).unwrap();
    assert_eq!(verify_bundle_dir(dir, &sums).unwrap(), expected);
    fs::write(&a, b"b").unwrap();
    assert!(verify_bundle_dir(dir, &sums).is_err());
    fs::remove_file(&a).unwrap();
    assert!(verify_bundle_dir(dir, &sums).is_err());
    fs::write(&a, b"a").unwrap();
    fs::write(dir.join("extra"), b"").unwrap();
    assert!(verify_bundle_dir(dir, &sums).is_err());
    fs::remove_file(dir.join("extra")).unwrap();
    fs::create_dir(dir.join("empty-dir")).unwrap();
    assert!(verify_bundle_dir(dir, &sums).is_err());
}

#[test]
fn compares_across_buffer_boundaries_and_reports_prefix_mismatch() {
    let temp = tempfile::tempdir().unwrap();
    let dir = temp.path();
    let reference = dir.join("ref");
    let candidate = dir.join("cand");
    fs::create_dir(&reference).unwrap();
    fs::create_dir(&candidate).unwrap();
    let bytes = vec![0; 8192];
    fs::write(reference.join("a"), &bytes).unwrap();
    fs::write(candidate.join("a"), [&bytes[..], b"x"].concat()).unwrap();
    let report = compare_arch_outputs(&reference, &candidate, &["a"]).unwrap();
    assert_eq!(report.verdict, ComparisonVerdict::Diverged);
    assert_eq!(
        report.files[0].first_mismatch,
        Some(FirstMismatch {
            byte_offset: 8192,
            reference_byte: None,
            candidate_byte: Some(b'x'),
            reference_len: 8192,
            candidate_len: 8193,
        })
    );
    for invalid in [&[][..], &["a", "a"], &["../a"]] {
        assert!(compare_arch_outputs(&reference, &candidate, invalid).is_err());
    }
}

#[test]
fn same_host_fixture_allows_matching_targets_and_manifest_atomic_replace() {
    let temp = tempfile::tempdir().unwrap();
    let dir = temp.path();
    for root in ["reference", "candidate"] {
        fs::create_dir(dir.join(root)).unwrap();
        fs::write(dir.join(root).join("artifact"), b"same-host").unwrap();
    }
    let output = cli(dir)
        .args([
            "compare",
            "--reference-dir",
            "reference",
            "--candidate-dir",
            "candidate",
            "--reference-target",
            "x86_64-unknown-linux-gnu",
            "--candidate-target",
            "x86_64-unknown-linux-gnu",
            "--source-sha",
            "standalone-fixture",
            "--proof-kind",
            "same-host-fixture",
            "--receipt",
            "fixture.json",
            "artifact",
        ])
        .output()
        .unwrap();
    assert!(output.status.success(), "{output:?}");
    let receipt: CrossArchReceiptManifest = serde_json::from_slice(&output.stdout).unwrap();
    assert_eq!(receipt.proof_kind, ProofKind::SameHostFixture);
    assert_eq!(receipt.comparison.verdict, ComparisonVerdict::Match);

    let receipt_path = dir.join("fixture.json");
    assert!(receipt.write_no_clobber(&receipt_path).is_err());
    receipt.write_atomic(&receipt_path).unwrap();
    assert_eq!(
        fs::read_to_string(&receipt_path).unwrap(),
        receipt.to_canonical_json().unwrap()
    );
}

#[cfg(unix)]
#[test]
fn rejects_symlinks_in_bundle_root_subdir_and_file() {
    use std::os::unix::fs::symlink;

    let temp = tempfile::tempdir().unwrap();
    let dir = temp.path();
    let real_bundle = dir.join("bundle");
    let nested = real_bundle.join("nested");
    fs::create_dir_all(&nested).unwrap();
    fs::write(nested.join("ok.bin"), b"ok").unwrap();
    let sums = real_bundle.join("SHA256SUMS");
    write_sha256sums(&real_bundle, &["nested/ok.bin"], &sums).unwrap();
    assert!(verify_bundle_dir(&real_bundle, &sums).is_ok());

    // Symlinked bundle root is rejected.
    let link_root = dir.join("bundle-link");
    symlink(&real_bundle, &link_root).unwrap();
    assert!(verify_bundle_dir(&link_root, &sums).is_err());

    // Symlinked file inside bundle is rejected.
    let outside = dir.join("outside.bin");
    fs::write(&outside, b"outside").unwrap();
    let file_link = real_bundle.join("sneaky.bin");
    symlink(&outside, &file_link).unwrap();
    assert!(verify_bundle_dir(&real_bundle, &sums).is_err());
    assert!(write_sha256sums(&real_bundle, &["sneaky.bin"], &dir.join("s2")).is_err());
    fs::remove_file(&file_link).unwrap();

    // Symlinked subdirectory inside bundle is rejected.
    let outside_dir = dir.join("outside-dir");
    fs::create_dir(&outside_dir).unwrap();
    fs::write(outside_dir.join("inner.bin"), b"inner").unwrap();
    let dir_link = real_bundle.join("sub-link");
    symlink(&outside_dir, &dir_link).unwrap();
    assert!(verify_bundle_dir(&real_bundle, &sums).is_err());
    assert!(write_sha256sums(&real_bundle, &["sub-link/inner.bin"], &dir.join("s3")).is_err());
}

#[cfg(unix)]
#[test]
fn local_staging_cleanup_refuses_symlinks_and_preserves_targets() {
    use std::os::unix::fs::symlink;

    let temp = tempfile::tempdir().unwrap();
    let dir = temp.path();

    // Symlinked staging root: cleanup must refuse and preserve both symlink and target.
    let target_dir = dir.join("victim");
    fs::create_dir(&target_dir).unwrap();
    fs::write(
        target_dir.join(DEFAULT_STAGING_CLAIM_FILE),
        format!("{VALID_TOKEN}\n"),
    )
    .unwrap();
    let link_dir = dir.join("stage-link");
    symlink(&target_dir, &link_dir).unwrap();
    assert!(
        cleanup_local_staging_claim(&link_dir, VALID_TOKEN, DEFAULT_STAGING_CLAIM_FILE).is_err()
    );
    assert!(target_dir.join(DEFAULT_STAGING_CLAIM_FILE).exists());
    assert!(fs::symlink_metadata(&link_dir).is_ok());

    // Symlinked claim file inside real staging dir: cleanup must refuse and preserve dir.
    let real_stage = dir.join("stage-real");
    let claim_path =
        acquire_local_staging_claim(&real_stage, VALID_TOKEN, DEFAULT_STAGING_CLAIM_FILE).unwrap();
    fs::remove_file(&claim_path).unwrap();
    let outside_claim = dir.join("outside-claim");
    fs::write(&outside_claim, format!("{VALID_TOKEN}\n")).unwrap();
    symlink(&outside_claim, &claim_path).unwrap();
    assert!(
        cleanup_local_staging_claim(&real_stage, VALID_TOKEN, DEFAULT_STAGING_CLAIM_FILE).is_err()
    );
    assert!(real_stage.exists());
    assert!(outside_claim.exists());
}

#[cfg(unix)]
#[test]
fn rendered_sh_staging_scripts_execute_and_refuse_tampering() {
    use std::os::unix::fs::{PermissionsExt, symlink};

    let temp = tempfile::tempdir().unwrap();
    let parent = temp.path().to_str().unwrap();
    let stage_path = temp.path().join("stage-sh-1");
    let remote_dir = stage_path.to_str().unwrap();

    // Render claim script via CLI and execute it with POSIX sh.
    let claim_cli = cli(temp.path())
        .args([
            "staging-script",
            "--remote-dir",
            remote_dir,
            "--allowed-parent",
            parent,
            "--claim-token",
            VALID_TOKEN,
            "--mode",
            "claim",
        ])
        .output()
        .unwrap();
    assert!(claim_cli.status.success(), "{claim_cli:?}");
    let claim_script = String::from_utf8(claim_cli.stdout).unwrap();
    let run_claim = Command::new("sh")
        .args(["-c", &claim_script])
        .output()
        .unwrap();
    assert!(run_claim.status.success(), "{run_claim:?}");
    assert!(stage_path.is_dir());
    let mode = fs::symlink_metadata(&stage_path)
        .unwrap()
        .permissions()
        .mode()
        & 0o777;
    assert_eq!(mode, 0o700);
    assert_eq!(
        fs::read_to_string(stage_path.join(DEFAULT_STAGING_CLAIM_FILE)).unwrap(),
        format!("{VALID_TOKEN}\n")
    );

    // Re-running claim script fails because mkdir is exclusive.
    let rerun_claim = Command::new("sh")
        .args(["-c", &claim_script])
        .output()
        .unwrap();
    assert!(!rerun_claim.status.success());

    // Wrong token cleanup script refuses and preserves directory.
    let wrong_cleanup =
        RemoteStagingSpec::new(remote_dir, parent, OTHER_TOKEN, DEFAULT_STAGING_CLAIM_FILE)
            .unwrap()
            .render_verified_cleanup_script()
            .unwrap();
    let run_wrong = Command::new("sh")
        .args(["-c", &wrong_cleanup])
        .output()
        .unwrap();
    assert!(!run_wrong.status.success());
    assert!(stage_path.exists());

    // Valid cleanup script via CLI removes directory and verifies absence.
    let cleanup_cli = cli(temp.path())
        .args([
            "staging-script",
            "--remote-dir",
            remote_dir,
            "--allowed-parent",
            parent,
            "--claim-token",
            VALID_TOKEN,
            "--mode",
            "cleanup",
        ])
        .output()
        .unwrap();
    assert!(cleanup_cli.status.success(), "{cleanup_cli:?}");
    let cleanup_script = String::from_utf8(cleanup_cli.stdout).unwrap();
    let run_cleanup = Command::new("sh")
        .args(["-c", &cleanup_script])
        .output()
        .unwrap();
    assert!(run_cleanup.status.success(), "{run_cleanup:?}");
    assert!(fs::symlink_metadata(&stage_path).is_err());

    // Cleanup script refuses symlinked staging dir and preserves target.
    let victim = temp.path().join("victim-dir");
    fs::create_dir(&victim).unwrap();
    fs::write(
        victim.join(DEFAULT_STAGING_CLAIM_FILE),
        format!("{VALID_TOKEN}\n"),
    )
    .unwrap();
    symlink(&victim, &stage_path).unwrap();
    let run_symlink = Command::new("sh")
        .args(["-c", &cleanup_script])
        .output()
        .unwrap();
    assert!(!run_symlink.status.success());
    assert!(victim.join(DEFAULT_STAGING_CLAIM_FILE).exists());
    assert!(fs::symlink_metadata(&stage_path).is_ok());
}

#[cfg(unix)]
#[test]
fn rejects_symlinked_parent_and_target_on_manifest_and_sums_write() {
    use std::{collections::BTreeMap, os::unix::fs::symlink};

    use harbor_evidence::cross_arch::{
        ArchComparisonReport, CROSS_ARCH_RECEIPT_SCHEMA_VERSION, FileComparison,
    };

    let temp = tempfile::tempdir().unwrap();
    let dir = temp.path();

    let real_parent = dir.join("real-parent");
    fs::create_dir(&real_parent).unwrap();
    let link_parent = dir.join("link-parent");
    symlink(&real_parent, &link_parent).unwrap();

    let hash = "a".repeat(64);
    let manifest = CrossArchReceiptManifest {
        schema_version: CROSS_ARCH_RECEIPT_SCHEMA_VERSION,
        proof_kind: ProofKind::SameHostFixture,
        source_sha: "standalone-fixture".to_owned(),
        reference_target: "x86_64-unknown-linux-gnu".to_owned(),
        candidate_target: "x86_64-unknown-linux-gnu".to_owned(),
        lockfile_sha256s: BTreeMap::new(),
        build_commands: BTreeMap::new(),
        inputs_sha256: BTreeMap::new(),
        outputs_sha256: BTreeMap::from([("out.bin".to_owned(), hash.clone())]),
        comparison: ArchComparisonReport {
            verdict: ComparisonVerdict::Match,
            files: vec![FileComparison {
                path: "out.bin".to_owned(),
                reference_sha256: hash.clone(),
                candidate_sha256: hash,
                matched: true,
                first_mismatch: None,
            }],
        },
    };

    // Symlinked parent directory is rejected for write_atomic and write_no_clobber.
    let via_link_parent = link_parent.join("receipt.json");
    assert!(manifest.write_atomic(&via_link_parent).is_err());
    assert!(manifest.write_no_clobber(&via_link_parent).is_err());
    assert!(!real_parent.join("receipt.json").exists());

    // Pre-existing symlink at target path is rejected for write_atomic, write_no_clobber, and write_sha256sums.
    let victim = dir.join("victim.txt");
    fs::write(&victim, b"preserve").unwrap();
    let target_link = real_parent.join("target-link.json");
    symlink(&victim, &target_link).unwrap();
    assert!(manifest.write_atomic(&target_link).is_err());
    assert!(manifest.write_no_clobber(&target_link).is_err());
    assert_eq!(fs::read(&victim).unwrap(), b"preserve");

    let bundle_dir = dir.join("bundle");
    fs::create_dir(&bundle_dir).unwrap();
    fs::write(bundle_dir.join("a.bin"), b"abc").unwrap();
    let sums_link = real_parent.join("SHA256SUMS");
    symlink(&victim, &sums_link).unwrap();
    assert!(write_sha256sums(&bundle_dir, &["a.bin"], &sums_link).is_err());
    assert!(write_sha256sums(&bundle_dir, &["a.bin"], &link_parent.join("SHA256SUMS")).is_err());
    assert_eq!(fs::read(&victim).unwrap(), b"preserve");
}
