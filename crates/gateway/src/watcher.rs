//! Datei-Watcher für `servers.d/`.
//!
//! Änderungen an Manifesten lösen nach kurzer Sammelzeit einen Reload aus.
//! Der Reload ersetzt die Registry und benachrichtigt alle Sessions mit
//! `tools/list_changed`.

use std::path::Path;
use std::sync::Arc;
use std::time::Duration;

use notify::{EventKind, RecursiveMode, Watcher};
use tracing::{info, warn};

use crate::state::Shared;

/// Beobachtet das Manifest-Verzeichnis.
///
/// Der zurückgegebene Watcher muss am Leben bleiben, sonst endet die
/// Überwachung.
pub fn spawn(shared: Arc<Shared>, dir: &Path) -> Result<notify::RecommendedWatcher, notify::Error> {
    let (sender, mut receiver) = tokio::sync::mpsc::unbounded_channel();
    let mut watcher =
        notify::recommended_watcher(move |event: notify::Result<notify::Event>| match event {
            Ok(event) if is_manifest_change(&event.kind) => {
                let _ = sender.send(());
            }
            Ok(_) => {}
            Err(error) => warn!(%error, "Datei-Watcher meldet Fehler"),
        })?;
    watcher.watch(dir, RecursiveMode::NonRecursive)?;

    let dir = dir.to_path_buf();
    tokio::spawn(async move {
        while receiver.recv().await.is_some() {
            tokio::time::sleep(Duration::from_millis(300)).await;
            while receiver.try_recv().is_ok() {}
            info!(dir = %dir.display(), "Manifest-Änderung erkannt");
            shared.reload(&dir).await;
        }
    });

    Ok(watcher)
}

/// Relevante Ereignisse: neue, geänderte oder entfernte Manifeste.
fn is_manifest_change(kind: &EventKind) -> bool {
    matches!(
        kind,
        EventKind::Create(_) | EventKind::Modify(_) | EventKind::Remove(_)
    )
}
