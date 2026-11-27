//! Byte-level cross-architecture evidence. Callers supply source and run provenance.
//! Path checks reject symlinks in a stable tree; they do not prevent concurrent
//! path replacement. Keep evidence trees and their ancestors under trusted control.

use std::{
    collections::{BTreeMap, BTreeSet},
    fs::{self, DirBuilder, File, OpenOptions},
    io::{self, BufRead, BufReader, Read, Write},
    path::{Component, Path, PathBuf},
};

use anyhow::{Context, Result, bail, ensure};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use walkdir::WalkDir;

use crate::{artifact::digest, receipt::write_atomic, write_json_atomic};

pub const CROSS_ARCH_RECEIPT_SCHEMA_VERSION: u32 = 1;
pub const DEFAULT_ALLOWED_STAGING_PARENT: &str = "/tmp";
pub const DEFAULT_STAGING_CLAIM_FILE: &str = ".harbor-staging-claim";

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, clap::ValueEnum)]
#[serde(rename_all = "snake_case")]
pub enum ProofKind {
    Native,
    SameHostFixture,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ComparisonVerdict {
    Match,
    Diverged,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct FirstMismatch {
    pub byte_offset: u64,
    pub reference_byte: Option<u8>,
    pub candidate_byte: Option<u8>,
    pub reference_len: u64,
    pub candidate_len: u64,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct FileComparison {
    pub path: String,
    pub reference_sha256: String,
    pub candidate_sha256: String,
    pub matched: bool,
    pub first_mismatch: Option<FirstMismatch>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ArchComparisonReport {
    pub verdict: ComparisonVerdict,
    pub files: Vec<FileComparison>,
}

impl ArchComparisonReport {
    pub(crate) fn verified_outputs(&self) -> BTreeMap<String, String> {
        self.files
            .iter()
            .filter(|file| file.matched)
            .map(|file| (file.path.clone(), file.candidate_sha256.clone()))
            .collect()
    }

    fn validate(&self) -> Result<()> {
        ensure!(!self.files.is_empty(), "comparison has no files");
        ensure!(
            self.files
                .windows(2)
                .all(|pair| pair[0].path < pair[1].path),
            "comparison paths must be unique and sorted"
        );
        for file in &self.files {
            validate_relative_path(&file.path)?;
            validate_sha256(&file.reference_sha256)?;
            validate_sha256(&file.candidate_sha256)?;
            if let Some(mismatch) = &file.first_mismatch {
                ensure!(
                    !file.matched
                        && mismatch.reference_byte != mismatch.candidate_byte
                        && mismatch.byte_offset <= mismatch.reference_len
                        && mismatch.byte_offset <= mismatch.candidate_len
                        && (mismatch.byte_offset < mismatch.reference_len)
                            == mismatch.reference_byte.is_some()
                        && (mismatch.byte_offset < mismatch.candidate_len)
                            == mismatch.candidate_byte.is_some(),
                    "inconsistent first mismatch: {}",
                    file.path
                );
            } else {
                ensure!(
                    file.matched && file.reference_sha256 == file.candidate_sha256,
                    "inconsistent matching file: {}",
                    file.path
                );
            }
        }
        ensure!(
            (self.verdict == ComparisonVerdict::Match)
                == self.files.iter().all(|file| file.matched),
            "inconsistent comparison verdict"
        );
        Ok(())
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct CrossArchReceiptManifest {
    pub schema_version: u32,
    pub proof_kind: ProofKind,
    pub source_sha: String,
    pub reference_target: String,
    pub candidate_target: String,
    pub lockfile_sha256s: BTreeMap<String, String>,
    #[serde(default)]
    pub build_commands: BTreeMap<String, String>,
    pub inputs_sha256: BTreeMap<String, String>,
    /// Candidate digests of files confirmed byte-identical to the reference.
    pub outputs_sha256: BTreeMap<String, String>,
    pub comparison: ArchComparisonReport,
}

impl CrossArchReceiptManifest {
    pub fn validate(&self) -> Result<()> {
        ensure!(
            self.schema_version == CROSS_ARCH_RECEIPT_SCHEMA_VERSION,
            "unsupported cross-arch receipt schema"
        );
        let valid_source_sha = match self.proof_kind {
            ProofKind::Native => lower_hex(&self.source_sha, 40),
            ProofKind::SameHostFixture => {
                self.source_sha == "standalone-fixture" || lower_hex(&self.source_sha, 40)
            }
        };
        ensure!(valid_source_sha, "invalid source SHA");
        for target in [&self.reference_target, &self.candidate_target] {
            let parts: Vec<&str> = target.split('-').collect();
            ensure!(
                parts.len() >= 2
                    && parts.iter().all(|part| {
                        !part.is_empty()
                            && part
                                .bytes()
                                .all(|byte| byte.is_ascii_alphanumeric() || byte == b'_')
                    }),
                "invalid target triple: {target:?}"
            );
        }
        ensure!(
            self.proof_kind != ProofKind::Native || self.reference_target != self.candidate_target,
            "native proof requires distinct targets"
        );
        for map in [
            &self.lockfile_sha256s,
            &self.inputs_sha256,
            &self.outputs_sha256,
        ] {
            for (path, sha256) in map {
                validate_relative_path(path)?;
                validate_sha256(sha256)?;
            }
        }
        for label in self.build_commands.keys() {
            validate_relative_path(label)?;
        }
        self.comparison.validate()?;
        ensure!(
            self.outputs_sha256 == self.comparison.verified_outputs(),
            "output digests disagree with verified comparison files"
        );
        Ok(())
    }

    pub fn to_canonical_json(&self) -> Result<String> {
        self.validate()?;
        let mut json = serde_json::to_string_pretty(self)?;
        json.push('\n');
        Ok(json)
    }

    pub fn write_atomic(&self, path: &Path) -> Result<()> {
        self.validate()?;
        validate_output_path(path)?;
        write_json_atomic(path, self, true)
    }

    pub fn write_no_clobber(&self, path: &Path) -> Result<()> {
        self.validate()?;
        validate_output_path(path)?;
        write_json_atomic(path, self, false)
    }
}

fn is_lower_hex(byte: u8) -> bool {
    byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte)
}

fn lower_hex(value: &str, len: usize) -> bool {
    value.len() == len && value.bytes().all(is_lower_hex)
}

fn validate_sha256(value: &str) -> Result<()> {
    ensure!(lower_hex(value, 64), "invalid SHA-256 digest");
    Ok(())
}

pub fn validate_relative_path(path: &str) -> Result<()> {
    ensure!(
        !path.contains(['\\', '\0', '\r', '\n'])
            && path.split('/').all(|part| !matches!(part, "" | "." | ".."))
            && Path::new(path)
                .components()
                .all(|part| matches!(part, Component::Normal(_)))
            && path.as_bytes().get(1).is_none_or(|byte| *byte != b':'),
        "unsafe relative path: {path:?}"
    );
    Ok(())
}

fn sorted_paths<'a>(paths: &[&'a str]) -> Result<BTreeSet<&'a str>> {
    ensure!(!paths.is_empty(), "at least one file is required");
    let mut sorted = BTreeSet::new();
    for &path in paths {
        validate_relative_path(path)?;
        ensure!(sorted.insert(path), "duplicate path: {path}");
    }
    Ok(sorted)
}

/// Verify that `path` and every walked ancestor component are real (non-symlink) directories
/// (Linux-strict ancestor symlink validation; callers must still prevent concurrent mutation).
fn require_real_dir(path: &Path) -> Result<()> {
    let mut prefix = std::path::PathBuf::new();
    for part in path.components() {
        prefix.push(part);
        require_type(&prefix, fs::FileType::is_dir, "directory")?;
    }
    // Reject an empty path and confirm the supplied spelling resolves as a directory.
    require_type(path, fs::FileType::is_dir, "directory")
}

fn validate_output_path(path: &Path) -> Result<&Path> {
    ensure!(
        path.file_name().is_some(),
        "output path must include a filename: {}",
        path.display()
    );
    let parent = path
        .parent()
        .filter(|parent| !parent.as_os_str().is_empty())
        .unwrap_or_else(|| Path::new("."));
    require_real_dir(parent)?;
    match fs::symlink_metadata(path) {
        Ok(metadata) => ensure!(
            !metadata.file_type().is_symlink(),
            "refusing to write to symlink target: {}",
            path.display()
        ),
        Err(error) if error.kind() == io::ErrorKind::NotFound => {}
        Err(error) => {
            return Err(error).with_context(|| format!("checking {}", path.display()));
        }
    }
    Ok(parent)
}

fn require_type(path: &Path, kind: fn(&fs::FileType) -> bool, description: &str) -> Result<()> {
    let metadata =
        fs::symlink_metadata(path).with_context(|| format!("checking {}", path.display()))?;
    ensure!(
        kind(&metadata.file_type()),
        "expected a non-symlink {description}: {}",
        path.display()
    );
    Ok(())
}

pub(crate) fn open_regular_path(path: &Path) -> Result<File> {
    if let Some(parent) = path
        .parent()
        .filter(|parent| !parent.as_os_str().is_empty())
    {
        require_real_dir(parent)?;
    }
    require_type(path, fs::FileType::is_file, "regular file")?;
    File::open(path).with_context(|| format!("opening {}", path.display()))
}

pub fn open_regular_no_symlinks(root: &Path, rel: &str) -> Result<File> {
    validate_relative_path(rel)?;
    ensure!(!root.as_os_str().is_empty(), "bundle root is empty");
    open_regular_path(&root.join(rel))
}

pub fn write_sha256sums(
    bundle_dir: &Path,
    relative_paths: &[&str],
    sums_path: &Path,
) -> Result<BTreeMap<String, String>> {
    let parent = validate_output_path(sums_path)?;
    require_real_dir(bundle_dir)?;
    let destination = parent
        .canonicalize()?
        .join(sums_path.file_name().context("missing sums filename")?);
    let canonical_bundle_dir = bundle_dir.canonicalize()?;
    let mut sums = BTreeMap::new();
    for path in sorted_paths(relative_paths)? {
        let mut file = open_regular_no_symlinks(bundle_dir, path)?;
        ensure!(
            canonical_bundle_dir.join(path) != destination,
            "checksum manifest cannot replace a bundle member: {path}"
        );
        sums.insert(
            path.to_owned(),
            digest(&mut file).with_context(|| format!("hashing {path}"))?,
        );
    }
    write_atomic(sums_path, true, |file| {
        for (path, sha256) in &sums {
            writeln!(file, "{sha256}  {path}")?;
        }
        Ok(())
    })?;
    Ok(sums)
}

pub fn parse_sha256sums(content: &str) -> Result<BTreeMap<String, String>> {
    let content = content
        .strip_suffix('\n')
        .context("checksum manifest must end with LF")?;
    let mut sums = BTreeMap::new();
    for line in content.split('\n') {
        let (sha256, path) = line.split_once("  ").context("malformed checksum line")?;
        validate_sha256(sha256)?;
        validate_relative_path(path)?;
        ensure!(
            sums.insert(path.to_owned(), sha256.to_owned()).is_none(),
            "duplicate checksum path: {path}"
        );
    }
    Ok(sums)
}

pub(crate) fn read_sha256sums(path: &Path) -> Result<BTreeMap<String, String>> {
    let mut content = String::new();
    open_regular_path(path)?.read_to_string(&mut content)?;
    parse_sha256sums(&content).with_context(|| format!("parsing {}", path.display()))
}

pub fn verify_sha256sums(bundle_dir: &Path, sums_path: &Path) -> Result<BTreeMap<String, String>> {
    require_real_dir(bundle_dir)?;
    let sums = read_sha256sums(sums_path)?;
    for (path, expected) in &sums {
        let actual = digest(&mut open_regular_no_symlinks(bundle_dir, path)?)
            .with_context(|| format!("hashing {path}"))?;
        ensure!(actual == *expected, "checksum mismatch: {path}");
    }
    Ok(sums)
}

fn normalize_bundle_relative(root: &Path, path: &Path) -> Result<String> {
    let relative = path
        .strip_prefix(root)?
        .to_str()
        .context("bundle path must be UTF-8")?;
    if std::path::MAIN_SEPARATOR == '/' {
        ensure!(
            !relative.contains('\\'),
            "unexpected backslash in bundle path: {relative:?}"
        );
        Ok(relative.to_owned())
    } else {
        Ok(relative.replace(std::path::MAIN_SEPARATOR, "/"))
    }
}

fn insert_ancestor_dirs(allowed_dirs: &mut BTreeSet<String>, relative: &str) {
    let mut current = relative;
    while let Some((parent, _)) = current.rsplit_once('/') {
        if !allowed_dirs.insert(parent.to_owned()) {
            break;
        }
        current = parent;
    }
}

pub fn verify_bundle_dir(bundle_dir: &Path, sums_path: &Path) -> Result<BTreeMap<String, String>> {
    let sums = verify_sha256sums(bundle_dir, sums_path)?;
    let root = bundle_dir.canonicalize()?;
    let sums_file = sums_path.canonicalize()?;
    let mut allowed_dirs = BTreeSet::new();
    for relative in sums.keys() {
        insert_ancestor_dirs(&mut allowed_dirs, relative);
    }
    if sums_file.strip_prefix(&root).is_ok() {
        let sums_rel = normalize_bundle_relative(&root, &sums_file)?;
        insert_ancestor_dirs(&mut allowed_dirs, &sums_rel);
    }
    for entry in WalkDir::new(&root).follow_links(false) {
        let entry = entry.context("walking bundle directory")?;
        let path = entry.path();
        if entry.file_type().is_dir() {
            if path == root {
                continue;
            }
            let relative = normalize_bundle_relative(&root, path)?;
            ensure!(
                allowed_dirs.contains(&relative),
                "unexpected bundle directory: {relative}"
            );
            continue;
        }
        ensure!(
            entry.file_type().is_file(),
            "not a regular bundle file: {}",
            path.display()
        );
        if path == sums_file {
            continue;
        }
        let relative = normalize_bundle_relative(&root, path)?;
        ensure!(
            sums.contains_key(&relative),
            "unexpected bundle file: {relative}"
        );
    }
    Ok(sums)
}

pub fn compare_arch_outputs(
    reference_dir: &Path,
    candidate_dir: &Path,
    artifact_names: &[&str],
) -> Result<ArchComparisonReport> {
    let files = sorted_paths(artifact_names)?
        .into_iter()
        .map(|path| compare_file(reference_dir, candidate_dir, path))
        .collect::<Result<Vec<_>>>()?;
    let verdict = if files.iter().all(|file| file.matched) {
        ComparisonVerdict::Match
    } else {
        ComparisonVerdict::Diverged
    };
    Ok(ArchComparisonReport { verdict, files })
}

fn compare_file(reference_dir: &Path, candidate_dir: &Path, path: &str) -> Result<FileComparison> {
    let mut reference = BufReader::new(open_regular_no_symlinks(reference_dir, path)?);
    let mut candidate = BufReader::new(open_regular_no_symlinks(candidate_dir, path)?);
    let mut reference_hash = Sha256::new();
    let mut candidate_hash = Sha256::new();
    let (mut reference_len, mut candidate_len) = (0_u64, 0_u64);
    let mut first = None;
    loop {
        let left = reference.fill_buf()?;
        let right = candidate.fill_buf()?;
        if left.is_empty() && right.is_empty() {
            break;
        }
        let common = left.len().min(right.len());
        if first.is_none() {
            first = if common == 0 {
                Some((
                    reference_len.min(candidate_len),
                    left.first().copied(),
                    right.first().copied(),
                ))
            } else {
                left.iter()
                    .zip(right)
                    .enumerate()
                    .find_map(|(index, (&a, &b))| {
                        (a != b).then_some((reference_len + index as u64, Some(a), Some(b)))
                    })
            };
        }
        // Read boundaries may differ. Keep shared bytes aligned until real EOF.
        let (l, r) = if common == 0 {
            (left.len(), right.len())
        } else {
            (common, common)
        };
        reference_hash.update(&left[..l]);
        candidate_hash.update(&right[..r]);
        reference_len += l as u64;
        candidate_len += r as u64;
        reference.consume(l);
        candidate.consume(r);
    }
    let reference_sha256 = format!("{:x}", reference_hash.finalize());
    let candidate_sha256 = format!("{:x}", candidate_hash.finalize());
    Ok(FileComparison {
        path: path.to_owned(),
        matched: first.is_none() && reference_sha256 == candidate_sha256,
        reference_sha256,
        candidate_sha256,
        first_mismatch: first.map(
            |(byte_offset, reference_byte, candidate_byte)| FirstMismatch {
                byte_offset,
                reference_byte,
                candidate_byte,
                reference_len,
                candidate_len,
            },
        ),
    })
}

fn is_safe_staging_byte(byte: u8) -> bool {
    byte.is_ascii_alphanumeric() || matches!(byte, b'.' | b'_' | b'-')
}

fn validate_safe_component(value: &str, label: &str) -> Result<()> {
    ensure!(
        !value.is_empty()
            && !matches!(value, "." | "..")
            && !value.starts_with('-')
            && value.bytes().all(is_safe_staging_byte),
        "unsafe {label}: {value:?}"
    );
    Ok(())
}

/// Validate a strict lowercase 8-4-4-4-12 UUID claim token.
pub fn validate_claim_token(token: &str) -> Result<()> {
    let bytes = token.as_bytes();
    ensure!(
        bytes.len() == 36
            && bytes.iter().enumerate().all(|(index, &byte)| {
                if matches!(index, 8 | 13 | 18 | 23) {
                    byte == b'-'
                } else {
                    is_lower_hex(byte)
                }
            }),
        "claim token must be a lowercase 8-4-4-4-12 UUID"
    );
    Ok(())
}

fn validate_allowed_parent(allowed_parent: &str) -> Result<()> {
    let rest = allowed_parent
        .strip_prefix('/')
        .context("allowed staging parent must be an absolute POSIX path")?;
    ensure!(
        !rest.is_empty() && !rest.ends_with('/'),
        "allowed staging parent cannot be root or end with a slash: {allowed_parent:?}"
    );
    for segment in rest.split('/') {
        validate_safe_component(segment, "staging parent segment")?;
    }
    Ok(())
}

/// Validate that `remote_dir` is a strict direct child of `allowed_parent` with
/// shell-safe characters and no traversal or root-deletion hazards.
pub fn validate_remote_staging_dir(remote_dir: &str, allowed_parent: &str) -> Result<()> {
    validate_allowed_parent(allowed_parent)?;
    let prefix = format!("{allowed_parent}/");
    let child = remote_dir
        .strip_prefix(&prefix)
        .with_context(|| format!("remote staging dir must be under {allowed_parent:?}"))?;
    ensure!(
        !child.contains('/'),
        "remote staging dir must be a direct child of {allowed_parent:?}: {remote_dir:?}"
    );
    validate_safe_component(child, "remote staging dir name")?;
    Ok(())
}

fn validate_claim_file_name(claim_file: &str) -> Result<()> {
    ensure!(
        !claim_file.contains('/'),
        "claim file name must not contain path separators: {claim_file:?}"
    );
    validate_safe_component(claim_file, "claim file name")
}

/// Remote staging specification; path-based verification + removal is non-atomic under untrusted concurrent mutation and requires a private/non-hostile parent directory.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RemoteStagingSpec {
    pub remote_dir: String,
    pub allowed_parent: String,
    pub claim_token: String,
    pub claim_file: String,
}

impl RemoteStagingSpec {
    pub fn new(
        remote_dir: impl Into<String>,
        allowed_parent: impl Into<String>,
        claim_token: impl Into<String>,
        claim_file: impl Into<String>,
    ) -> Result<Self> {
        let spec = Self {
            remote_dir: remote_dir.into(),
            allowed_parent: allowed_parent.into(),
            claim_token: claim_token.into(),
            claim_file: claim_file.into(),
        };
        spec.validate()?;
        Ok(spec)
    }

    pub fn validate(&self) -> Result<()> {
        validate_claim_token(&self.claim_token)?;
        validate_remote_staging_dir(&self.remote_dir, &self.allowed_parent)?;
        validate_claim_file_name(&self.claim_file)?;
        Ok(())
    }

    #[must_use]
    pub fn claim_path(&self) -> String {
        format!("{}/{}", self.remote_dir, self.claim_file)
    }

    pub fn render_claim_script(&self) -> Result<String> {
        self.validate()?;
        let claim_path = self.claim_path();
        Ok(format!(
            concat!(
                "set -eu\n",
                "umask 077\n",
                "remote_dir='{remote_dir}'\n",
                "claim_file='{claim_path}'\n",
                "expected_token='{token}'\n",
                "mkdir -m 700 -- \"$remote_dir\"\n",
                "[ ! -L \"$remote_dir\" ]\n",
                "[ -d \"$remote_dir\" ]\n",
                "(set -C; printf '%s\\n' \"$expected_token\" > \"$claim_file\")\n",
                "[ ! -L \"$claim_file\" ]\n",
                "[ -f \"$claim_file\" ]\n",
                "printf '%s\\n' \"$expected_token\" | cmp -s - \"$claim_file\"\n",
            ),
            remote_dir = self.remote_dir,
            claim_path = claim_path,
            token = self.claim_token,
        ))
    }

    pub fn render_verified_cleanup_script(&self) -> Result<String> {
        self.validate()?;
        let claim_path = self.claim_path();
        Ok(format!(
            concat!(
                "set -eu\n",
                "umask 077\n",
                "remote_dir='{remote_dir}'\n",
                "claim_file='{claim_path}'\n",
                "expected_token='{token}'\n",
                "[ ! -L \"$remote_dir\" ]\n",
                "[ -d \"$remote_dir\" ]\n",
                "[ ! -L \"$claim_file\" ]\n",
                "[ -f \"$claim_file\" ]\n",
                "printf '%s\\n' \"$expected_token\" | cmp -s - \"$claim_file\"\n",
                "rm -rf -- \"$remote_dir\"\n",
                "[ ! -e \"$remote_dir\" ] && [ ! -L \"$remote_dir\" ]\n",
            ),
            remote_dir = self.remote_dir,
            claim_path = claim_path,
            token = self.claim_token,
        ))
    }
}

pub fn acquire_local_staging_claim(
    staging_dir: &Path,
    claim_token: &str,
    claim_file_name: &str,
) -> Result<PathBuf> {
    validate_claim_token(claim_token)?;
    validate_claim_file_name(claim_file_name)?;
    let parent = staging_dir
        .parent()
        .filter(|path| !path.as_os_str().is_empty())
        .context("staging directory must have a parent directory")?;
    require_real_dir(parent)?;

    let mut dir_builder = DirBuilder::new();
    #[cfg(unix)]
    {
        use std::os::unix::fs::DirBuilderExt;
        dir_builder.mode(0o700);
    }
    dir_builder
        .create(staging_dir)
        .with_context(|| format!("creating staging directory {}", staging_dir.display()))?;
    require_type(staging_dir, fs::FileType::is_dir, "directory")?;

    let claim_path = staging_dir.join(claim_file_name);
    let mut options = OpenOptions::new();
    options.write(true).create_new(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.mode(0o600);
    }
    let mut file = options
        .open(&claim_path)
        .with_context(|| format!("creating staging claim {}", claim_path.display()))?;
    file.write_all(format!("{claim_token}\n").as_bytes())?;
    file.sync_all()?;
    require_type(&claim_path, fs::FileType::is_file, "regular file")?;
    Ok(claim_path)
}

/// Verify the staging claim and remove `staging_dir`; path-based verification + removal is non-atomic under untrusted concurrent mutation and requires a private/non-hostile parent directory.
pub fn cleanup_local_staging_claim(
    staging_dir: &Path,
    claim_token: &str,
    claim_file_name: &str,
) -> Result<()> {
    validate_claim_token(claim_token)?;
    validate_claim_file_name(claim_file_name)?;
    ensure!(
        staging_dir.file_name().is_some(),
        "staging directory must have a terminal directory name: {}",
        staging_dir.display()
    );
    ensure!(
        staging_dir
            .parent()
            .is_some_and(|parent| !parent.as_os_str().is_empty()),
        "staging directory must have a non-empty parent directory: {}",
        staging_dir.display()
    );
    ensure!(
        !staging_dir
            .components()
            .any(|component| matches!(component, Component::ParentDir)),
        "staging directory must not contain parent traversal: {}",
        staging_dir.display()
    );
    require_real_dir(staging_dir)?;

    let claim_path = staging_dir.join(claim_file_name);
    require_type(&claim_path, fs::FileType::is_file, "regular file")?;
    let expected = format!("{claim_token}\n");
    let mut actual = Vec::new();
    File::open(&claim_path)
        .with_context(|| format!("reading staging claim {}", claim_path.display()))?
        .take((expected.len() + 1) as u64)
        .read_to_end(&mut actual)?;
    ensure!(
        actual == expected.as_bytes(),
        "staging claim token mismatch in {}",
        claim_path.display()
    );

    fs::remove_dir_all(staging_dir)
        .with_context(|| format!("removing staging directory {}", staging_dir.display()))?;
    match fs::symlink_metadata(staging_dir) {
        Err(error) if error.kind() == io::ErrorKind::NotFound => Ok(()),
        Ok(_) => bail!(
            "staging directory still exists after cleanup: {}",
            staging_dir.display()
        ),
        Err(error) => {
            Err(error).with_context(|| format!("verifying removal of {}", staging_dir.display()))
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const VALID_TOKEN: &str = "01234567-89ab-cdef-0123-456789abcdef";
    const OTHER_TOKEN: &str = "fedcba98-7654-3210-fedc-ba9876543210";

    #[test]
    fn validates_claim_tokens_strictly() {
        assert!(validate_claim_token(VALID_TOKEN).is_ok());
        for invalid in [
            "",
            "01234567-89AB-cdef-0123-456789abcdef",
            "01234567-89ab-cdef-0123-456789abcde",
            "01234567-89ab-cdef-0123-456789abcdeff",
            "01234567_89ab-cdef-0123-456789abcdef",
            "0123456789abcdef0123456789abcdef",
            "01234567-89ab-cdef-0123-456789abcdef\n",
            "01234567-89ab-cdef-0123-456789abcdeg",
        ] {
            assert!(
                validate_claim_token(invalid).is_err(),
                "accepted {invalid:?}"
            );
        }
    }

    #[test]
    fn validates_remote_staging_dir_strictly() {
        assert!(validate_remote_staging_dir("/tmp/harbor-stage-1", "/tmp").is_ok());
        assert!(validate_remote_staging_dir("/var/tmp/run_42.a", "/var/tmp").is_ok());
        for (remote_dir, parent) in [
            ("/", "/"),
            ("/tmp", "/tmp"),
            ("/tmp/", "/tmp"),
            ("/tmp/a/b", "/tmp"),
            ("/tmp/..", "/tmp"),
            ("/tmp/.", "/tmp"),
            ("/tmp/-rf", "/tmp"),
            ("/tmp/foo bar", "/tmp"),
            ("/tmp/$(id)", "/tmp"),
            ("/tmp/foo;rm", "/tmp"),
            ("/tmp/foo'bar", "/tmp"),
            ("/other/stage", "/tmp"),
            ("tmp/stage", "tmp"),
            ("/tmp/stage", "/tmp/"),
            ("/tmp/stage", "/"),
        ] {
            assert!(
                validate_remote_staging_dir(remote_dir, parent).is_err(),
                "accepted ({remote_dir:?}, {parent:?})"
            );
        }
    }

    #[test]
    fn parses_and_rejects_malformed_sha256sums() {
        let valid_hash = "a".repeat(64);
        let parsed = parse_sha256sums(&format!("{valid_hash}  dir/file.bin\n")).unwrap();
        assert_eq!(parsed.get("dir/file.bin"), Some(&valid_hash));

        for bad in [
            "",
            "\n",
            &format!("{valid_hash}  a"),
            &format!("{valid_hash}  a\r\n"),
            &format!("{valid_hash} a\n"),
            &format!("{}  a\n", "A".repeat(64)),
            &format!("{}  a\n", "a".repeat(63)),
            &format!("{valid_hash}  ../a\n"),
            &format!("{valid_hash}  /abs/a\n"),
            &format!("{valid_hash}  a\\b\n"),
            &format!("{valid_hash}  a\n{valid_hash}  a\n"),
        ] {
            assert!(parse_sha256sums(bad).is_err(), "accepted {bad:?}");
        }
    }

    #[test]
    fn manifest_validation_checks_schema_targets_and_unknown_fields() {
        let hash = "a".repeat(64);
        let report = ArchComparisonReport {
            verdict: ComparisonVerdict::Match,
            files: vec![FileComparison {
                path: "out.bin".to_owned(),
                reference_sha256: hash.clone(),
                candidate_sha256: hash.clone(),
                matched: true,
                first_mismatch: None,
            }],
        };
        let mut manifest = CrossArchReceiptManifest {
            schema_version: CROSS_ARCH_RECEIPT_SCHEMA_VERSION,
            proof_kind: ProofKind::SameHostFixture,
            source_sha: "standalone-fixture".to_owned(),
            reference_target: "x86_64-unknown-linux-gnu".to_owned(),
            candidate_target: "x86_64-unknown-linux-gnu".to_owned(),
            lockfile_sha256s: BTreeMap::new(),
            build_commands: BTreeMap::from([("build".to_owned(), "cargo build".to_owned())]),
            inputs_sha256: BTreeMap::new(),
            outputs_sha256: BTreeMap::from([("out.bin".to_owned(), hash.clone())]),
            comparison: report,
        };
        assert!(manifest.validate().is_ok());

        manifest.proof_kind = ProofKind::Native;
        assert!(manifest.validate().is_err());

        manifest.candidate_target = "aarch64-unknown-linux-gnu".to_owned();
        // Native proof must still reject "standalone-fixture" source_sha.
        assert!(manifest.validate().is_err());

        manifest.source_sha = "a".repeat(40);
        assert!(manifest.validate().is_ok());

        // Single-segment target triple is rejected; two-segment target passes.
        manifest.candidate_target = "linux".to_owned();
        assert!(manifest.validate().is_err());
        manifest.candidate_target = "wasm32-wasip1".to_owned();
        assert!(manifest.validate().is_ok());
        manifest.candidate_target = "aarch64-unknown-linux-gnu".to_owned();

        manifest.schema_version = 2;
        assert!(manifest.validate().is_err());
        manifest.schema_version = CROSS_ARCH_RECEIPT_SCHEMA_VERSION;

        let mut json: serde_json::Value =
            serde_json::from_str(&manifest.to_canonical_json().unwrap()).unwrap();
        json.as_object_mut()
            .unwrap()
            .insert("unexpected".to_owned(), serde_json::Value::Bool(true));
        assert!(serde_json::from_value::<CrossArchReceiptManifest>(json).is_err());
    }

    #[test]
    fn native_proof_rejects_standalone_fixture_source_sha() {
        let hash = "a".repeat(64);
        let manifest = CrossArchReceiptManifest {
            schema_version: CROSS_ARCH_RECEIPT_SCHEMA_VERSION,
            proof_kind: ProofKind::Native,
            source_sha: "standalone-fixture".to_owned(),
            reference_target: "x86_64-unknown-linux-gnu".to_owned(),
            candidate_target: "aarch64-unknown-linux-musl".to_owned(),
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
        assert!(manifest.validate().is_err());
    }

    #[test]
    fn cleanup_local_staging_claim_rejects_root_and_parent_traversal_paths() {
        let temp = tempfile::tempdir().unwrap();
        let parent = temp.path();
        let child = parent.join("child");
        fs::create_dir(&child).unwrap();
        // Place a valid claim file in the parent directory so `<child>/..` would otherwise see it.
        fs::write(
            parent.join(DEFAULT_STAGING_CLAIM_FILE),
            format!("{VALID_TOKEN}\n"),
        )
        .unwrap();

        let traversal = child.join("..");
        for dangerous in [
            Path::new("/"),
            Path::new("."),
            Path::new(".."),
            traversal.as_path(),
        ] {
            assert!(
                cleanup_local_staging_claim(dangerous, VALID_TOKEN, DEFAULT_STAGING_CLAIM_FILE)
                    .is_err(),
                "accepted dangerous staging path {}",
                dangerous.display()
            );
        }
        assert!(parent.join(DEFAULT_STAGING_CLAIM_FILE).exists());
        assert!(child.exists());
    }

    #[test]
    fn local_staging_claim_acquire_and_cleanup_lifecycle() {
        let temp = tempfile::tempdir().unwrap();
        let stage = temp.path().join("stage-1");
        let claim =
            acquire_local_staging_claim(&stage, VALID_TOKEN, DEFAULT_STAGING_CLAIM_FILE).unwrap();
        assert_eq!(
            fs::read_to_string(&claim).unwrap(),
            format!("{VALID_TOKEN}\n")
        );
        // Exclusive creation refuses reuse.
        assert!(
            acquire_local_staging_claim(&stage, VALID_TOKEN, DEFAULT_STAGING_CLAIM_FILE).is_err()
        );
        // Wrong token refuses cleanup and preserves directory.
        assert!(
            cleanup_local_staging_claim(&stage, OTHER_TOKEN, DEFAULT_STAGING_CLAIM_FILE).is_err()
        );
        assert!(stage.exists());
        // Missing claim file refuses cleanup and preserves directory.
        fs::remove_file(&claim).unwrap();
        assert!(
            cleanup_local_staging_claim(&stage, VALID_TOKEN, DEFAULT_STAGING_CLAIM_FILE).is_err()
        );
        assert!(stage.exists());
        // Restore valid claim and clean up.
        fs::write(&claim, format!("{VALID_TOKEN}\n")).unwrap();
        cleanup_local_staging_claim(&stage, VALID_TOKEN, DEFAULT_STAGING_CLAIM_FILE).unwrap();
        assert!(!stage.exists());
    }
}
