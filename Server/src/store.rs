//! Everything is one SQLite file, which is the right size for this.

use std::sync::{Arc, Mutex};

use rusqlite::{params, Connection};

#[derive(Clone)]
pub struct Store {
    connection: Arc<Mutex<Connection>>,
}

#[derive(Debug, Clone)]
pub struct License {
    pub key: String,
    pub plan: String,
    pub note: String,
    pub created_at: i64,
    pub expires_at: Option<i64>,
    pub revoked: bool,
}

#[derive(Debug, Clone)]
pub struct Activation {
    pub device_id: String,
    pub device_name: String,
    pub activated_at: i64,
    pub last_seen: i64,
}

#[derive(Debug, Clone)]
pub struct Release {
    pub platform: String,
    pub build: i64,
    pub version: String,
    pub url: String,
    pub notes: String,
    pub required: bool,
}

impl Store {
    pub fn open(path: &str) -> rusqlite::Result<Self> {
        let connection = Connection::open(path)?;
        connection.execute_batch(
            "PRAGMA journal_mode = WAL;
             PRAGMA foreign_keys = ON;

             CREATE TABLE IF NOT EXISTS licenses (
                 key         TEXT PRIMARY KEY,
                 plan        TEXT NOT NULL DEFAULT 'standard',
                 note        TEXT NOT NULL DEFAULT '',
                 created_at  INTEGER NOT NULL,
                 expires_at  INTEGER,
                 revoked     INTEGER NOT NULL DEFAULT 0
             );

             -- One row per licence is the whole one-device rule. There is no
             -- counting and no cleanup job: a second device simply cannot get
             -- a row, and moving to a new phone means releasing the old one.
             CREATE TABLE IF NOT EXISTS activations (
                 license      TEXT PRIMARY KEY REFERENCES licenses(key) ON DELETE CASCADE,
                 device_id    TEXT NOT NULL,
                 device_name  TEXT NOT NULL DEFAULT '',
                 activated_at INTEGER NOT NULL,
                 last_seen    INTEGER NOT NULL
             );

             CREATE TABLE IF NOT EXISTS releases (
                 platform TEXT PRIMARY KEY,
                 build    INTEGER NOT NULL,
                 version  TEXT NOT NULL,
                 url      TEXT NOT NULL,
                 notes    TEXT NOT NULL DEFAULT '',
                 required INTEGER NOT NULL DEFAULT 0
             );

             CREATE TABLE IF NOT EXISTS trial_usage (
                 device_id    TEXT NOT NULL,
                 day          TEXT NOT NULL,
                 used         INTEGER NOT NULL DEFAULT 0,
                 active_since INTEGER,
                 last_tick    INTEGER,
                 ip           TEXT NOT NULL DEFAULT '',
                 PRIMARY KEY (device_id, day)
             );

             CREATE TABLE IF NOT EXISTS trial_devices (
                 device_id  TEXT PRIMARY KEY,
                 tz_minutes INTEGER NOT NULL DEFAULT 0,
                 first_seen INTEGER NOT NULL
             );",
        )?;
        Ok(Self { connection: Arc::new(Mutex::new(connection)) })
    }

    fn with<T>(&self, body: impl FnOnce(&Connection) -> rusqlite::Result<T>) -> rusqlite::Result<T> {
        let guard = self.connection.lock().unwrap_or_else(|e| e.into_inner());
        body(&guard)
    }

    // MARK: - Licences

    pub fn create_license(&self, key: &str, plan: &str, note: &str, expires_at: Option<i64>) -> rusqlite::Result<()> {
        self.with(|c| {
            c.execute(
                "INSERT INTO licenses (key, plan, note, created_at, expires_at) VALUES (?1, ?2, ?3, ?4, ?5)",
                params![key, plan, note, now(), expires_at],
            )?;
            Ok(())
        })
    }

    pub fn license(&self, key: &str) -> rusqlite::Result<Option<License>> {
        self.with(|c| {
            let mut statement = c.prepare(
                "SELECT key, plan, note, created_at, expires_at, revoked FROM licenses WHERE key = ?1",
            )?;
            let mut rows = statement.query(params![key])?;
            match rows.next()? {
                Some(row) => Ok(Some(License {
                    key: row.get(0)?,
                    plan: row.get(1)?,
                    note: row.get(2)?,
                    created_at: row.get(3)?,
                    expires_at: row.get(4)?,
                    revoked: row.get::<_, i64>(5)? != 0,
                })),
                None => Ok(None),
            }
        })
    }

    pub fn set_revoked(&self, key: &str, revoked: bool) -> rusqlite::Result<usize> {
        self.with(|c| {
            c.execute(
                "UPDATE licenses SET revoked = ?2 WHERE key = ?1",
                params![key, i64::from(revoked)],
            )
        })
    }

    pub fn all_licenses(&self) -> rusqlite::Result<Vec<(License, Option<Activation>)>> {
        self.with(|c| {
            let mut statement = c.prepare(
                "SELECT l.key, l.plan, l.note, l.created_at, l.expires_at, l.revoked,
                        a.device_id, a.device_name, a.activated_at, a.last_seen
                 FROM licenses l LEFT JOIN activations a ON a.license = l.key
                 ORDER BY l.created_at DESC",
            )?;
            let rows = statement.query_map([], |row| {
                let license = License {
                    key: row.get(0)?,
                    plan: row.get(1)?,
                    note: row.get(2)?,
                    created_at: row.get(3)?,
                    expires_at: row.get(4)?,
                    revoked: row.get::<_, i64>(5)? != 0,
                };
                let device: Option<String> = row.get(6)?;
                let activation = device.map(|device_id| Activation {
                    device_id,
                    device_name: row.get(7).unwrap_or_default(),
                    activated_at: row.get(8).unwrap_or_default(),
                    last_seen: row.get(9).unwrap_or_default(),
                });
                Ok((license, activation))
            })?;
            rows.collect()
        })
    }

    // MARK: - Activations

    pub fn activation(&self, key: &str) -> rusqlite::Result<Option<Activation>> {
        self.with(|c| {
            let mut statement = c.prepare(
                "SELECT device_id, device_name, activated_at, last_seen FROM activations WHERE license = ?1",
            )?;
            let mut rows = statement.query(params![key])?;
            match rows.next()? {
                Some(row) => Ok(Some(Activation {
                    device_id: row.get(0)?,
                    device_name: row.get(1)?,
                    activated_at: row.get(2)?,
                    last_seen: row.get(3)?,
                })),
                None => Ok(None),
            }
        })
    }

    pub fn activate(&self, key: &str, device_id: &str, device_name: &str) -> rusqlite::Result<()> {
        self.with(|c| {
            c.execute(
                "INSERT INTO activations (license, device_id, device_name, activated_at, last_seen)
                 VALUES (?1, ?2, ?3, ?4, ?4)
                 ON CONFLICT(license) DO UPDATE SET last_seen = ?4, device_name = ?3",
                params![key, device_id, device_name, now()],
            )?;
            Ok(())
        })
    }

    pub fn deactivate(&self, key: &str) -> rusqlite::Result<usize> {
        self.with(|c| c.execute("DELETE FROM activations WHERE license = ?1", params![key]))
    }

    pub fn touch(&self, key: &str) -> rusqlite::Result<usize> {
        self.with(|c| {
            c.execute("UPDATE activations SET last_seen = ?2 WHERE license = ?1", params![key, now()])
        })
    }

    // MARK: - Releases

    pub fn release(&self, platform: &str) -> rusqlite::Result<Option<Release>> {
        self.with(|c| {
            let mut statement = c.prepare(
                "SELECT platform, build, version, url, notes, required FROM releases WHERE platform = ?1",
            )?;
            let mut rows = statement.query(params![platform])?;
            match rows.next()? {
                Some(row) => Ok(Some(Release {
                    platform: row.get(0)?,
                    build: row.get(1)?,
                    version: row.get(2)?,
                    url: row.get(3)?,
                    notes: row.get(4)?,
                    required: row.get::<_, i64>(5)? != 0,
                })),
                None => Ok(None),
            }
        })
    }

    pub fn publish(&self, release: &Release) -> rusqlite::Result<()> {
        self.with(|c| {
            c.execute(
                "INSERT INTO releases (platform, build, version, url, notes, required)
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6)
                 ON CONFLICT(platform) DO UPDATE SET
                     build = ?2, version = ?3, url = ?4, notes = ?5, required = ?6",
                params![
                    release.platform, release.build, release.version,
                    release.url, release.notes, i64::from(release.required)
                ],
            )?;
            Ok(())
        })
    }
}

#[derive(Debug, Clone, Default)]
pub struct TrialRow {
    pub used: i64,
    pub active_since: Option<i64>,
    pub last_tick: Option<i64>,
}

impl Store {
    pub fn trial_timezone(&self, device: &str, offered: i64) -> rusqlite::Result<i64> {
        self.with(|c| {
            c.execute(
                "INSERT OR IGNORE INTO trial_devices (device_id, tz_minutes, first_seen) VALUES (?1, ?2, ?3)",
                params![device, offered.clamp(-840, 840), now()],
            )?;
            c.query_row("SELECT tz_minutes FROM trial_devices WHERE device_id = ?1", params![device], |row| row.get(0))
        })
    }

    pub fn trial_row(&self, device: &str, day: &str) -> rusqlite::Result<TrialRow> {
        self.with(|c| {
            let mut statement = c.prepare("SELECT used, active_since, last_tick FROM trial_usage WHERE device_id = ?1 AND day = ?2")?;
            let mut rows = statement.query(params![device, day])?;
            match rows.next()? {
                Some(row) => Ok(TrialRow { used: row.get(0)?, active_since: row.get(1)?, last_tick: row.get(2)? }),
                None => Ok(TrialRow::default()),
            }
        })
    }

    pub fn trial_save(&self, device: &str, day: &str, row: &TrialRow, ip: &str) -> rusqlite::Result<()> {
        self.with(|c| {
            c.execute(
                "INSERT INTO trial_usage (device_id, day, used, active_since, last_tick, ip) VALUES (?1, ?2, ?3, ?4, ?5, ?6)
                 ON CONFLICT(device_id, day) DO UPDATE SET used = excluded.used, active_since = excluded.active_since, last_tick = excluded.last_tick",
                params![device, day, row.used, row.active_since, row.last_tick, ip],
            )?;
            Ok(())
        })
    }

    pub fn trial_devices_on_ip(&self, ip: &str, day: &str) -> rusqlite::Result<i64> {
        self.with(|c| {
            c.query_row(
                "SELECT COUNT(DISTINCT device_id) FROM trial_usage WHERE ip = ?1 AND day = ?2",
                params![ip, day],
                |row| row.get(0),
            )
        })
    }

    pub fn trial_known(&self, device: &str, day: &str) -> rusqlite::Result<bool> {
        self.with(|c| {
            c.query_row(
                "SELECT COUNT(*) FROM trial_usage WHERE device_id = ?1 AND day = ?2",
                params![device, day],
                |row| row.get::<_, i64>(0),
            )
            .map(|count| count > 0)
        })
    }
}

pub fn now() -> i64 {
    chrono::Utc::now().timestamp()
}
