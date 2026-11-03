//! Prüft Warteschlange, Grenzen und Persistenz ohne Gateway und ohne Backend.

use std::time::Duration;

use mac_compute_jobs::{CancelOutcome, ErrorKind, JobState, JobStore, Limits, StoreError};
use serde_json::{Value, json};

fn limits() -> Limits {
    Limits::default()
}

fn store() -> JobStore {
    JobStore::in_memory(limits()).expect("Queue")
}

async fn submit(store: &JobStore, tool: &str, backend: &str, priority: u8) -> String {
    store
        .submit(tool, backend, json!({}), priority)
        .await
        .expect("Aufgabe angenommen")
        .id
}

#[tokio::test]
async fn annahme_setzt_wartezustand_und_position() {
    let store = store();
    let first = submit(&store, "render_png", "render", 5).await;
    let second = submit(&store, "mock_echo", "mock", 9).await;

    let job = store.get(&first).await.expect("Aufgabe");
    assert_eq!(job.state, JobState::Queued);
    assert_eq!(job.progress, 0);
    assert!(job.id.starts_with("job-"));
    assert!(job.started_at.is_none());

    assert_eq!(store.position(&first).await.expect("Position"), Some(1));
    assert_eq!(store.position(&second).await.expect("Position"), Some(0));
}

#[tokio::test]
async fn volle_warteschlange_wird_abgelehnt() {
    let store = JobStore::in_memory(Limits {
        max_queue: 1,
        max_queue_per_backend: 1,
        ..Limits::default()
    })
    .expect("Queue");

    submit(&store, "mock_echo", "mock", 5).await;
    let error = store
        .submit("mock_echo", "mock", json!({}), 5)
        .await
        .expect_err("zweite Aufgabe muss abgelehnt werden");
    assert!(
        matches!(error, StoreError::QueueFull { limit: 1 }),
        "{error}"
    );
}

#[tokio::test]
async fn ein_backend_fuellt_die_queue_nicht_allein() {
    let store = JobStore::in_memory(Limits {
        max_queue: 8,
        max_queue_per_backend: 1,
        ..Limits::default()
    })
    .expect("Queue");

    submit(&store, "mock_echo", "mock", 5).await;
    let error = store
        .submit("mock_sleep", "mock", json!({}), 5)
        .await
        .expect_err("zweite Aufgabe desselben Backends muss abgelehnt werden");
    assert!(
        matches!(error, StoreError::QueueFullBackend { .. }),
        "{error}"
    );

    store
        .submit("render_png", "render", json!({}), 5)
        .await
        .expect("anderes Backend hat noch Platz");
}

#[tokio::test]
async fn anspruch_folgt_prioritaet_dann_alter() {
    let store = store();
    let low = submit(&store, "mock_echo", "mock", 1).await;
    tokio::time::sleep(Duration::from_millis(5)).await;
    let high = submit(&store, "mock_echo", "mock", 9).await;
    tokio::time::sleep(Duration::from_millis(5)).await;
    let middle = submit(&store, "mock_echo", "mock", 1).await;

    let first = store
        .claim_next()
        .await
        .expect("Anspruch")
        .expect("Aufgabe");
    assert_eq!(first.id, high);

    // Nur eine Aufgabe gleichzeitig: die weiteren bleiben wartend.
    assert!(store.claim_next().await.expect("Anspruch").is_none());

    store
        .set_progress(&high, 100, Some(JobState::Done))
        .await
        .expect_err("set_progress darf nicht abschließen");
    store
        .finish(&high, json!({"ok": true}))
        .await
        .expect("abgeschlossen");

    let second = store
        .claim_next()
        .await
        .expect("Anspruch")
        .expect("Aufgabe");
    assert_eq!(
        second.id, low,
        "ältere Aufgabe mit gleicher Priorität zuerst"
    );
    store.finish(&second.id, Value::Null).await.expect("fertig");
    let third = store
        .claim_next()
        .await
        .expect("Anspruch")
        .expect("Aufgabe");
    assert_eq!(third.id, middle);
}

#[tokio::test]
async fn anspruch_beachtet_beide_grenzen() {
    let store = JobStore::in_memory(Limits {
        max_queue: 8,
        max_queue_per_backend: 8,
        max_concurrent: 2,
        max_per_backend: 1,
    })
    .expect("Queue");

    let render = submit(&store, "render_png", "render", 5).await;
    let mock = submit(&store, "mock_echo", "mock", 5).await;

    let first = store
        .claim_next()
        .await
        .expect("Anspruch")
        .expect("Aufgabe");
    let second = store
        .claim_next()
        .await
        .expect("Anspruch")
        .expect("Aufgabe");
    let mut claimed = vec![first.id.clone(), second.id.clone()];
    claimed.sort();
    let mut expected = vec![render.clone(), mock.clone()];
    expected.sort();
    assert_eq!(claimed, expected, "beide Backends laufen parallel");

    let third = store
        .submit("render_png", "render", json!({}), 5)
        .await
        .expect("drittes Backend frei");
    store
        .submit("mock_sleep", "mock", json!({}), 5)
        .await
        .expect("Aufgabe");
    assert!(
        store.claim_next().await.expect("Anspruch").is_none(),
        "beide Backends sind ausgelastet"
    );

    store.finish(&render, Value::Null).await.expect("fertig");
    let next = store
        .claim_next()
        .await
        .expect("Anspruch")
        .expect("Aufgabe");
    assert_eq!(next.backend, "render", "nur das freie Backend läuft");
    assert_eq!(next.id, third.id);
}

#[tokio::test]
async fn fortschritt_und_phasen_werden_geprueft() {
    let store = store();
    let id = submit(&store, "video_encode", "video", 5).await;
    store.claim_next().await.expect("Anspruch");

    let job = store
        .set_progress(&id, 42, Some(JobState::Encoding))
        .await
        .expect("Phase gesetzt");
    assert_eq!(job.state, JobState::Encoding);
    assert_eq!(job.progress, 42);

    let error = store
        .set_progress(&id, 50, Some(JobState::Queued))
        .await
        .expect_err("Rückwärtswechsel ist unzulässig");
    assert!(
        matches!(error, StoreError::InvalidTransition { .. }),
        "{error}"
    );

    let error = store
        .set_progress(&id, 101, None)
        .await
        .expect_err("Fortschritt über 100");
    assert!(matches!(error, StoreError::InvalidProgress(101)), "{error}");
}

#[tokio::test]
async fn abschluss_setzt_done_und_ergebnis() {
    let store = store();
    let id = submit(&store, "mock_echo", "mock", 5).await;
    store.claim_next().await.expect("Anspruch");

    let job = store
        .finish(&id, json!({"content": [{"type": "text", "text": "hallo"}]}))
        .await
        .expect("abgeschlossen");
    assert_eq!(job.state, JobState::Done);
    assert_eq!(job.progress, 100);
    assert!(job.finished_at.is_some());
    assert_eq!(job.result.expect("Ergebnis")["content"][0]["text"], "hallo");

    let error = store
        .finish(&id, Value::Null)
        .await
        .expect_err("zweiter Abschluss ist unzulässig");
    assert!(
        matches!(error, StoreError::AlreadyFinished { .. }),
        "{error}"
    );
}

#[tokio::test]
async fn fehler_wird_mit_art_gespeichert() {
    let store = store();
    let id = submit(&store, "mock_sleep", "mock", 5).await;
    store.claim_next().await.expect("Anspruch");

    let job = store
        .fail(&id, ErrorKind::Timeout, "Zeitlimit überschritten")
        .await
        .expect("fehlgeschlagen");
    assert_eq!(job.state, JobState::Failed);
    let failure = job.error.expect("Fehler");
    assert_eq!(failure.kind, ErrorKind::Timeout);
    assert_eq!(failure.message, "Zeitlimit überschritten");
}

#[tokio::test]
async fn abbruch_wartend_und_laufend() {
    let store = JobStore::in_memory(Limits {
        max_queue: 8,
        max_queue_per_backend: 8,
        max_concurrent: 2,
        max_per_backend: 2,
    })
    .expect("Queue");

    let queued = submit(&store, "mock_echo", "mock", 5).await;
    match store.cancel(&queued).await.expect("Abbruch") {
        CancelOutcome::Cancelled { job, was_running } => {
            assert!(!was_running);
            assert_eq!(job.state, JobState::Cancelled);
        }
        other => panic!("unerwartet: {other:?}"),
    }

    let running = submit(&store, "mock_sleep", "mock", 5).await;
    store.claim_next().await.expect("Anspruch");
    match store.cancel(&running).await.expect("Abbruch") {
        CancelOutcome::Cancelled { job, was_running } => {
            assert!(was_running);
            assert_eq!(job.state, JobState::Cancelled);
        }
        other => panic!("unerwartet: {other:?}"),
    }

    match store.cancel(&running).await.expect("Abbruch wiederholt") {
        CancelOutcome::AlreadyFinished(job) => assert_eq!(job.state, JobState::Cancelled),
        other => panic!("unerwartet: {other:?}"),
    }
    assert!(store.get("job-unbekannt").await.is_err());
}

#[tokio::test]
async fn neustart_behaelt_wartende_und_markiert_laufende() {
    let dir = tempfile::tempdir().expect("Temp-Verzeichnis");
    let path = dir.path().join("state/jobs.sqlite");

    let waiting = {
        let store = JobStore::open(&path, limits()).expect("Queue");
        let running = submit(&store, "mock_sleep", "mock", 5).await;
        store
            .claim_next()
            .await
            .expect("Anspruch")
            .expect("Aufgabe");
        tokio::time::sleep(Duration::from_millis(5)).await;
        let waiting = submit(&store, "mock_echo", "mock", 5).await;
        (running, waiting)
    };

    let store = JobStore::open(&path, limits()).expect("Queue nach Neustart");
    assert_eq!(store.mark_interrupted().await.expect("markiert"), 1);

    let running = store.get(&waiting.0).await.expect("laufende Aufgabe");
    assert_eq!(running.state, JobState::Failed);
    assert_eq!(running.error.expect("Fehler").kind, ErrorKind::Interrupted);

    let waiting = store.get(&waiting.1).await.expect("wartende Aufgabe");
    assert_eq!(waiting.state, JobState::Queued);

    let next = store
        .claim_next()
        .await
        .expect("Anspruch")
        .expect("Aufgabe");
    assert_eq!(next.id, waiting.id, "wartende Aufgabe läuft nach Neustart");
}

#[tokio::test]
async fn grenzen_werden_geprueft() {
    assert!(Limits::default().validate().is_ok());
    assert!(
        Limits {
            max_queue: 0,
            ..Limits::default()
        }
        .validate()
        .is_err()
    );
    assert!(
        Limits {
            max_queue: 4,
            max_queue_per_backend: 8,
            ..Limits::default()
        }
        .validate()
        .is_err()
    );
    assert!(
        Limits {
            max_concurrent: 1,
            max_per_backend: 2,
            ..Limits::default()
        }
        .validate()
        .is_err()
    );
    assert!(
        JobStore::in_memory(Limits {
            max_queue: 0,
            ..Limits::default()
        })
        .is_err()
    );
}

#[tokio::test]
async fn zaehler_und_unbekannte_aufgabe() {
    let store = store();
    let done = submit(&store, "mock_echo", "mock", 5).await;
    store.claim_next().await.expect("Anspruch");
    store.finish(&done, Value::Null).await.expect("fertig");
    submit(&store, "mock_sleep", "mock", 5).await;

    let stats = store.stats().await.expect("Zähler");
    assert_eq!(stats.done, 1);
    assert_eq!(stats.queued, 1);
    assert_eq!(stats.running, 0);

    let error = store.get("job-unbekannt").await.expect_err("unbekannt");
    assert!(matches!(error, StoreError::UnknownJob(_)), "{error}");
    assert_eq!(
        store.position("job-unbekannt").await.err().map(|_| ()),
        Some(())
    );
}
