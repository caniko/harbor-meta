use std::{
    collections::BTreeMap,
    io::{self, Write},
    path::{Path, PathBuf},
    thread,
    time::Duration,
};

use anyhow::{Context, Result, bail, ensure};
use clap::{Args, Parser, Subcommand, ValueEnum};
use serde_json::json;

use crate::{
    Manifest, accept,
    artifact::digest,
    cross_arch::{
        CROSS_ARCH_RECEIPT_SCHEMA_VERSION, ComparisonVerdict, CrossArchReceiptManifest,
        DEFAULT_ALLOWED_STAGING_PARENT, DEFAULT_STAGING_CLAIM_FILE, ProofKind, RemoteStagingSpec,
        compare_arch_outputs, open_regular_path, read_sha256sums, validate_relative_path,
        verify_bundle_dir, write_sha256sums,
    },
    read_json, snapshot, validate_report, verify_http, verify_local, write_json_atomic,
};

#[derive(Parser)]
#[command(
    name = "harbor",
    version,
    about = "Shared Harbor development and production artifact contracts"
)]
pub struct Cli {
    #[command(subcommand)]
    command: Phase,
}

#[derive(Subcommand)]
enum Phase {
    /// Prepare immutable artifact identities and bind acceptance reports
    Dev {
        #[command(subcommand)]
        command: Dev,
    },
    /// Verify accepted local and served artifact bytes
    Prod {
        #[command(subcommand)]
        command: Prod,
    },
}

#[derive(Subcommand)]
enum Dev {
    Artifact {
        #[command(subcommand)]
        command: DevArtifact,
    },
    /// Cross-architecture bundle integrity, comparison receipts, and remote staging scripts
    CrossArch {
        #[command(subcommand)]
        command: DevCrossArch,
    },
}

#[derive(Subcommand)]
enum Prod {
    Artifact {
        #[command(subcommand)]
        command: ProdArtifact,
    },
}

#[derive(Subcommand)]
enum DevArtifact {
    Snapshot {
        #[arg(long)]
        manifest: PathBuf,
        #[arg(long)]
        roots: PathBuf,
    },
    Accept {
        #[arg(long)]
        manifest: PathBuf,
        #[arg(long)]
        report: PathBuf,
        #[arg(long)]
        required: PathBuf,
    },
}

#[derive(Clone, Copy, ValueEnum)]
enum StagingScriptMode {
    Claim,
    Cleanup,
}

#[derive(Subcommand)]
enum DevCrossArch {
    /// Hash listed bundle files and write a canonical SHA256SUMS manifest
    SumsWrite {
        #[arg(long)]
        bundle_dir: PathBuf,
        #[arg(long)]
        output: PathBuf,
        #[arg(required = true)]
        files: Vec<String>,
    },
    /// Verify a bundle directory against a SHA256SUMS manifest with no extra or symlinked entries
    VerifyBundle {
        #[arg(long)]
        bundle_dir: PathBuf,
        #[arg(long)]
        sums: PathBuf,
    },
    /// Compare reference and candidate outputs and emit a cross-arch receipt manifest
    Compare {
        #[arg(long)]
        reference_dir: PathBuf,
        #[arg(long)]
        candidate_dir: PathBuf,
        #[arg(long)]
        reference_target: String,
        #[arg(long)]
        candidate_target: String,
        #[arg(long)]
        source_sha: String,
        #[arg(long, value_enum, default_value_t = ProofKind::Native)]
        proof_kind: ProofKind,
        #[arg(long = "lockfile")]
        lockfiles: Vec<String>,
        #[arg(long)]
        input_sums: Option<PathBuf>,
        #[arg(long)]
        receipt: Option<PathBuf>,
        #[arg(required = true)]
        artifacts: Vec<String>,
    },
    /// Render a verified POSIX sh remote staging claim or cleanup script
    StagingScript {
        #[arg(long)]
        remote_dir: String,
        #[arg(long)]
        claim_token: String,
        #[arg(long, default_value = DEFAULT_ALLOWED_STAGING_PARENT)]
        allowed_parent: String,
        #[arg(long, default_value = DEFAULT_STAGING_CLAIM_FILE)]
        claim_file: String,
        #[arg(long, value_enum)]
        mode: StagingScriptMode,
    },
}

#[derive(Subcommand)]
enum ProdArtifact {
    VerifyLocal {
        #[arg(long)]
        manifest: PathBuf,
        #[arg(long)]
        root: PathBuf,
        #[arg(long)]
        backend: Option<PathBuf>,
    },
    VerifyHttp {
        #[arg(long)]
        manifest: PathBuf,
        #[arg(long)]
        url: String,
        #[arg(long, default_value = "app/")]
        prefix: String,
        #[arg(long, default_value_t = 1)]
        attempts: u32,
    },
}

#[derive(Clone, Copy, ValueEnum)]
enum Action {
    Snapshot,
    Accept,
    VerifyLocal,
    VerifyHttp,
}

/// Existing flags remain compatible with harbor-verify-artifact callers.
#[derive(Parser)]
#[command(name = "harbor-verify-artifact", version)]
pub struct CompatibilityCli {
    #[command(flatten)]
    args: CompatibilityArgs,
}

#[derive(Args)]
struct CompatibilityArgs {
    #[arg(value_enum)]
    action: Action,
    #[arg(long)]
    manifest: PathBuf,
    #[arg(long)]
    roots: Option<PathBuf>,
    #[arg(long)]
    report: Option<PathBuf>,
    #[arg(long)]
    required: Option<PathBuf>,
    #[arg(long)]
    root: Option<PathBuf>,
    #[arg(long)]
    backend: Option<PathBuf>,
    #[arg(long)]
    url: Option<String>,
    #[arg(long, default_value = "app/")]
    prefix: String,
    #[arg(long, default_value_t = 1)]
    attempts: u32,
}

pub fn run(cli: Cli) -> Result<()> {
    match cli.command {
        Phase::Dev {
            command: Dev::Artifact { command },
        } => match command {
            DevArtifact::Snapshot { manifest, roots } => prepare(&manifest, &roots),
            DevArtifact::Accept {
                manifest,
                report,
                required,
            } => bind(&manifest, &report, &required),
        },
        Phase::Dev {
            command: Dev::CrossArch { command },
        } => run_cross_arch(command),
        Phase::Prod {
            command: Prod::Artifact { command },
        } => match command {
            ProdArtifact::VerifyLocal {
                manifest,
                root,
                backend,
            } => local(&manifest, &root, backend.as_deref()),
            ProdArtifact::VerifyHttp {
                manifest,
                url,
                prefix,
                attempts,
            } => http(&manifest, &url, &prefix, attempts),
        },
    }
}

fn run_cross_arch(command: DevCrossArch) -> Result<()> {
    match command {
        DevCrossArch::SumsWrite {
            bundle_dir,
            output,
            files,
        } => {
            let refs: Vec<&str> = files.iter().map(String::as_str).collect();
            write_sha256sums(&bundle_dir, &refs, &output)?;
            Ok(())
        }
        DevCrossArch::VerifyBundle { bundle_dir, sums } => {
            verify_bundle_dir(&bundle_dir, &sums)?;
            Ok(())
        }
        DevCrossArch::Compare {
            reference_dir,
            candidate_dir,
            reference_target,
            candidate_target,
            source_sha,
            proof_kind,
            lockfiles,
            input_sums,
            receipt,
            artifacts,
        } => {
            let mut lockfile_sha256s = BTreeMap::new();
            for spec in &lockfiles {
                let (name, path) = spec
                    .split_once('=')
                    .with_context(|| format!("lockfile must be NAME=PATH: {spec:?}"))?;
                validate_relative_path(name)?;
                ensure!(!path.is_empty(), "lockfile path is empty for {name:?}");
                let mut file = open_regular_path(Path::new(path))?;
                let sha256 =
                    digest(&mut file).with_context(|| format!("hashing lockfile {path}"))?;
                ensure!(
                    lockfile_sha256s.insert(name.to_owned(), sha256).is_none(),
                    "duplicate lockfile name: {name}"
                );
            }
            let inputs_sha256 = match input_sums {
                Some(path) => read_sha256sums(&path)?,
                None => BTreeMap::new(),
            };
            let artifact_refs: Vec<&str> = artifacts.iter().map(String::as_str).collect();
            let comparison = compare_arch_outputs(&reference_dir, &candidate_dir, &artifact_refs)?;
            let manifest = CrossArchReceiptManifest {
                schema_version: CROSS_ARCH_RECEIPT_SCHEMA_VERSION,
                proof_kind,
                source_sha,
                reference_target,
                candidate_target,
                lockfile_sha256s,
                build_commands: BTreeMap::new(),
                inputs_sha256,
                outputs_sha256: comparison.verified_outputs(),
                comparison,
            };
            let json = manifest.to_canonical_json()?;
            if let Some(receipt_path) = receipt {
                manifest.write_no_clobber(&receipt_path)?;
            }
            io::stdout().write_all(json.as_bytes())?;
            if manifest.comparison.verdict == ComparisonVerdict::Diverged {
                bail!("cross-arch comparison diverged");
            }
            Ok(())
        }
        DevCrossArch::StagingScript {
            remote_dir,
            claim_token,
            allowed_parent,
            claim_file,
            mode,
        } => {
            let spec = RemoteStagingSpec::new(remote_dir, allowed_parent, claim_token, claim_file)?;
            let script = match mode {
                StagingScriptMode::Claim => spec.render_claim_script()?,
                StagingScriptMode::Cleanup => spec.render_verified_cleanup_script()?,
            };
            io::stdout().write_all(script.as_bytes())?;
            Ok(())
        }
    }
}

pub fn run_compatibility(cli: CompatibilityCli) -> Result<()> {
    let args = cli.args;
    match args.action {
        Action::Snapshot => prepare(
            &args.manifest,
            &args
                .roots
                .ok_or_else(|| anyhow::anyhow!("--roots is required"))?,
        ),
        Action::Accept => bind(
            &args.manifest,
            &args
                .report
                .ok_or_else(|| anyhow::anyhow!("--report is required"))?,
            &args
                .required
                .ok_or_else(|| anyhow::anyhow!("--required is required"))?,
        ),
        Action::VerifyLocal => local(
            &args.manifest,
            &args
                .root
                .ok_or_else(|| anyhow::anyhow!("--root is required"))?,
            args.backend.as_deref(),
        ),
        Action::VerifyHttp => http(
            &args.manifest,
            &args
                .url
                .ok_or_else(|| anyhow::anyhow!("--url is required"))?,
            &args.prefix,
            args.attempts,
        ),
    }
}

fn prepare(manifest: &std::path::Path, roots: &std::path::Path) -> Result<()> {
    let roots: BTreeMap<String, PathBuf> = read_json(roots)?;
    write_json_atomic(manifest, &snapshot(&roots)?, false)
}

fn bind(
    manifest: &std::path::Path,
    report: &std::path::Path,
    required: &std::path::Path,
) -> Result<()> {
    let accepted = accept(
        read_json(manifest)?,
        &read_json(report)?,
        &read_json::<Vec<String>>(required)?,
    )?;
    write_json_atomic(manifest, &accepted, true)
}

fn accepted(manifest: &std::path::Path) -> Result<Manifest> {
    let manifest: Manifest = read_json(manifest)?;
    let required = manifest
        .required_tests
        .as_ref()
        .filter(|tests| !tests.is_empty())
        .ok_or_else(|| anyhow::anyhow!("manifest has no required acceptance contract"))?;
    validate_report(&json!({"tests":manifest.tests}), required)?;
    Ok(manifest)
}

fn local(
    manifest: &std::path::Path,
    root: &std::path::Path,
    backend: Option<&std::path::Path>,
) -> Result<()> {
    verify_local(&accepted(manifest)?, root, backend)
}

fn http(manifest: &std::path::Path, url: &str, prefix: &str, attempts: u32) -> Result<()> {
    ensure!(attempts > 0, "verification attempts must be positive");
    let manifest = accepted(manifest)?;
    for attempt in 0..attempts {
        match verify_http(&manifest, url, prefix) {
            Ok(()) => return Ok(()),
            Err(error) if attempt + 1 == attempts => return Err(error),
            Err(_) => thread::sleep(Duration::from_secs(1)),
        }
    }
    unreachable!("positive attempts checked before loop")
}
