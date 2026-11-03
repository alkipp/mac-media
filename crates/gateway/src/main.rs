//! Startet den `mac-compute-gateway`.

use std::net::SocketAddr;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::{Duration, SystemTime};

use clap::Parser;
use mac_compute_gateway::{Config, Registry, Shared, router, watcher};
use mac_compute_jobs::{JobStore, Limits};
use tokio::net::TcpListener;
use tracing::{info, warn};
use tracing_appender::non_blocking::WorkerGuard;
use tracing_subscriber::{EnvFilter, fmt, layer::SubscriberExt, util::SubscriberInitExt};

/// Kommandozeilenargumente des Gateways.
#[derive(Debug, Parser)]
#[command(
    name = "mac-compute-gateway",
    version,
    about = "MCP-Gateway für native Mac-Backends"
)]
struct Cli {
    /// Adresse, an die der Gateway bindet (nur Loopback).
    #[arg(long, default_value = "127.0.0.1:8787")]
    bind: SocketAddr,

    /// Verzeichnis mit den Backend-Manifesten.
    #[arg(long)]
    servers_dir: PathBuf,

    /// Datei mit dem Bearer-Token.
    #[arg(long)]
    token_file: PathBuf,

    /// Verzeichnis für Logs (optional).
    #[arg(long)]
    log_dir: Option<PathBuf>,

    /// Verzeichnis für Datenbank und Laufzeitstatus.
    ///
    /// Ohne Angabe liegt es neben `servers_dir`, also unter
    /// `.../mac-compute/state`.
    #[arg(long)]
    state_dir: Option<PathBuf>,

    /// Höchstzahl wartender Aufgaben insgesamt.
    #[arg(long, default_value_t = Limits::default().max_queue)]
    max_queue: u32,

    /// Höchstzahl wartender Aufgaben je Backend.
    #[arg(long, default_value_t = Limits::default().max_queue_per_backend)]
    max_queue_per_backend: u32,

    /// Höchstzahl gleichzeitig laufender Aufgaben insgesamt.
    #[arg(long, default_value_t = Limits::default().max_concurrent)]
    max_concurrent: u32,

    /// Höchstzahl gleichzeitig laufender Aufgaben je Backend.
    #[arg(long, default_value_t = Limits::default().max_per_backend)]
    max_per_backend: u32,

    /// Übergangsfrist für einen abgelösten Token in Stunden; 0 schaltet sie ab.
    ///
    /// Gilt für `token.previous` neben der Token-Datei, gerechnet ab deren
    /// Änderungsdatum.
    #[arg(long, default_value_t = 168, value_parser = clap::value_parser!(u64).range(0..=720))]
    token_grace_hours: u64,
}

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    let cli = Cli::parse();
    let limits = Limits {
        max_queue: cli.max_queue,
        max_queue_per_backend: cli.max_queue_per_backend,
        max_concurrent: cli.max_concurrent,
        max_per_backend: cli.max_per_backend,
    };
    limits.validate()?;
    let config = match cli.state_dir {
        Some(state_dir) => Config::with_state_dir(
            cli.bind,
            cli.servers_dir,
            state_dir,
            &cli.token_file,
            cli.log_dir,
        )?,
        None => Config::new(cli.bind, cli.servers_dir, &cli.token_file, cli.log_dir)?,
    }
    .with_grace(Duration::from_secs(
        cli.token_grace_hours.saturating_mul(3600),
    ))?;

    // Der Guard hält den nicht-blockierenden Log-Writer bis zum Prozessende.
    let _log_guard = init_logging(config.log_dir.as_deref());

    if let Some(previous) = &config.previous {
        let remaining = previous
            .until
            .duration_since(SystemTime::now())
            .unwrap_or_default();
        info!(
            hours = remaining.as_secs() / 3600,
            "abgelöster Token wird noch akzeptiert"
        );
    }

    info!(
        bind = %config.bind,
        servers_dir = %config.servers_dir.display(),
        state_dir = %config.state_dir.display(),
        "Gateway startet"
    );

    let store = Arc::new(JobStore::open(
        &config.state_dir.join("jobs.sqlite"),
        limits,
    )?);
    let interrupted = store.mark_interrupted().await?;
    if interrupted > 0 {
        warn!(
            count = interrupted,
            "Aufgaben aus dem letzten Lauf als failed markiert"
        );
    }

    let registry = Registry::load(&config.servers_dir).await;
    let shared = Shared::new(registry, store);

    // Der Watcher muss bis zum Prozessende leben.
    let _watcher = match watcher::spawn(shared.clone(), &config.servers_dir) {
        Ok(watcher) => Some(watcher),
        Err(error) => {
            warn!(%error, "Datei-Watcher konnte nicht starten");
            None
        }
    };
    tokio::spawn(supervise(shared.clone()));
    for _ in 0..limits.max_concurrent.max(1) {
        tokio::spawn(Arc::clone(&shared).run_worker());
    }

    let listener = TcpListener::bind(config.bind).await?;
    axum::serve(listener, router(&config, shared))
        .with_graceful_shutdown(shutdown())
        .await?;
    Ok(())
}

/// Loggt nach stderr und, wenn gesetzt, als JSONL mit täglicher Rotation.
fn init_logging(log_dir: Option<&Path>) -> Option<WorkerGuard> {
    let filter = EnvFilter::try_from_default_env().unwrap_or_else(|_| EnvFilter::new("info"));
    let stderr = fmt::layer().with_writer(std::io::stderr).with_ansi(false);

    let Some(dir) = log_dir else {
        tracing_subscriber::registry()
            .with(filter)
            .with(stderr)
            .init();
        return None;
    };

    let appender = tracing_appender::rolling::Builder::new()
        .rotation(tracing_appender::rolling::Rotation::DAILY)
        .filename_prefix("gateway")
        .filename_suffix("jsonl")
        .build(dir)
        .expect("Log-Verzeichnis wurde bereits geprüft");
    let (writer, guard) = tracing_appender::non_blocking(appender);
    let file = fmt::layer().json().with_writer(writer).with_ansi(false);

    tracing_subscriber::registry()
        .with(filter)
        .with(stderr)
        .with(file)
        .init();
    Some(guard)
}

/// Prüft alle zwei Sekunden, ob ein Backend neu gestartet werden muss.
async fn supervise(shared: Arc<Shared>) {
    let mut ticker = tokio::time::interval(Duration::from_secs(2));
    ticker.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);
    loop {
        ticker.tick().await;
        shared.supervise_once().await;
    }
}

async fn shutdown() {
    if let Err(error) = tokio::signal::ctrl_c().await {
        tracing::warn!(%error, "kein Abbruchsignal empfangen");
    }
    info!("Gateway wird beendet");
}
