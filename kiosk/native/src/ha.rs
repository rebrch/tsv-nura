//! Home Assistant WebSocket client (same protocol flow as master-control's server/src/ha.rs):
//! auth, get_states + registries, subscribe to state_changed, run commands, ping every 30s.

use crate::{config::Config, view};
use anyhow::{Context, anyhow, bail};
use futures_util::{SinkExt, StreamExt};
use serde_json::{Value, json};
use std::{
    collections::{HashMap, HashSet},
    sync::Arc,
    time::{Duration, Instant},
};
use tokio::sync::mpsc;
use tokio_tungstenite::{connect_async, tungstenite::Message};

const GET_STATES_ID: u64 = 1;
const SUBSCRIBE_ID: u64 = 2;
const AREAS_ID: u64 = 3;
const DEVICES_ID: u64 = 4;
const ENTITIES_ID: u64 = 5;
const FIRST_FREE_ID: u64 = 6;

#[derive(Debug)]
pub enum Command {
    Toggle(String),
    /// light, brightness percent (0 = off)
    Brightness(String, i32),
}

/// Receives every new display snapshot (called from the HA thread).
pub type Publish = Box<dyn Fn(view::Snapshot) + Send>;

pub async fn run(cfg: Arc<Config>, publish: Publish, mut commands: mpsc::UnboundedReceiver<Command>) {
    let ws_url = format!(
        "{}/api/websocket",
        cfg.home_assistant.url.trim_end_matches('/').replacen("https://", "wss://", 1).replacen("http://", "ws://", 1)
    );
    let mut st = State {
        cfg: &cfg,
        publish: &publish,
        watched: view::watched(&cfg),
        entities: view::Entities::new(),
        registry: view::Registry::default(),
        pending: HashMap::new(),
    };
    let mut backoff = Duration::from_secs(1);
    loop {
        let token = match std::fs::read_to_string(&cfg.home_assistant.token_file) {
            Ok(t) => t.trim().to_string(),
            Err(e) => {
                tracing::error!("cannot read HA token {}: {e}", cfg.home_assistant.token_file.display());
                tokio::time::sleep(Duration::from_secs(30)).await;
                continue;
            }
        };
        let started = Instant::now();
        match st.session(&ws_url, &token, &mut commands).await {
            Ok(()) => return,
            Err(e) => tracing::warn!("Home Assistant connection lost: {e:#}"),
        }
        st.publish(false);
        if started.elapsed() > Duration::from_secs(60) {
            backoff = Duration::from_secs(1);
        }
        tokio::time::sleep(backoff).await;
        backoff = (backoff * 2).min(Duration::from_secs(30));
    }
}

struct State<'a> {
    cfg: &'a Config,
    publish: &'a Publish,
    watched: HashSet<String>,
    entities: view::Entities,
    registry: view::Registry,
    /// registry results collected until all three have arrived
    pending: HashMap<u64, Value>,
}

impl State<'_> {
    fn publish(&self, connected: bool) {
        (self.publish)(view::build(self.cfg, &self.entities, &self.registry, connected));
    }

    fn relevant(&self, id: &str) -> bool {
        id.starts_with("light.") || self.watched.contains(id)
    }

    async fn session(
        &mut self,
        url: &str,
        token: &str,
        commands: &mut mpsc::UnboundedReceiver<Command>,
    ) -> anyhow::Result<()> {
        let (ws, _) = tokio::time::timeout(Duration::from_secs(15), connect_async(url))
            .await
            .context("connect timeout")?
            .context("connecting")?;
        let (mut tx, mut rx) = ws.split();

        let mut recv_json = async || -> anyhow::Result<Value> {
            loop {
                match rx.next().await.ok_or_else(|| anyhow!("closed during auth"))?? {
                    Message::Text(t) => return Ok(serde_json::from_str(t.as_str())?),
                    Message::Close(f) => bail!("closed during auth: {f:?}"),
                    _ => {}
                }
            }
        };
        let hello = recv_json().await?;
        if hello["type"] != "auth_required" {
            bail!("unexpected greeting: {hello}");
        }
        tx.send(text(json!({"type": "auth", "access_token": token}))).await?;
        let auth = recv_json().await?;
        if auth["type"] != "auth_ok" {
            bail!("authentication failed: {}", auth["message"]);
        }
        tracing::info!(version = %auth["ha_version"], "connected to Home Assistant");

        self.pending.clear();
        // HA requires strictly increasing ids.
        tx.send(text(json!({"id": GET_STATES_ID, "type": "get_states"}))).await?;
        tx.send(text(json!({"id": SUBSCRIBE_ID, "type": "subscribe_events", "event_type": "state_changed"}))).await?;
        for (id, kind) in [
            (AREAS_ID, "config/area_registry/list"),
            (DEVICES_ID, "config/device_registry/list"),
            (ENTITIES_ID, "config/entity_registry/list"),
        ] {
            tx.send(text(json!({"id": id, "type": kind}))).await?;
        }

        let mut next_id = FIRST_FREE_ID;
        let mut ping = tokio::time::interval(Duration::from_secs(30));
        ping.tick().await;
        let mut awaiting_pong = false;

        loop {
            tokio::select! {
                msg = rx.next() => {
                    match msg.ok_or_else(|| anyhow!("connection closed"))?? {
                        Message::Text(t) => {
                            let v: Value = serde_json::from_str(t.as_str())?;
                            if v["type"] == "pong" { awaiting_pong = false; }
                            self.handle(v);
                        }
                        Message::Close(f) => bail!("closed by server: {f:?}"),
                        _ => {}
                    }
                }
                cmd = commands.recv() => {
                    let Some(cmd) = cmd else { return Ok(()) };
                    tracing::info!(?cmd, "command");
                    let msg = match &cmd {
                        Command::Toggle(entity) => json!({
                            "id": next_id, "type": "call_service",
                            "domain": "homeassistant", "service": "toggle",
                            "target": {"entity_id": entity},
                        }),
                        Command::Brightness(entity, 0) => json!({
                            "id": next_id, "type": "call_service",
                            "domain": "light", "service": "turn_off",
                            "target": {"entity_id": entity},
                        }),
                        Command::Brightness(entity, pct) => json!({
                            "id": next_id, "type": "call_service",
                            "domain": "light", "service": "turn_on",
                            "service_data": {"brightness_pct": pct.clamp(&1, &100)},
                            "target": {"entity_id": entity},
                        }),
                    };
                    tx.send(text(msg)).await?;
                    next_id += 1;
                }
                _ = ping.tick() => {
                    if awaiting_pong { bail!("ping timeout"); }
                    tx.send(text(json!({"id": next_id, "type": "ping"}))).await?;
                    next_id += 1;
                    awaiting_pong = true;
                }
            }
        }
    }

    fn handle(&mut self, v: Value) {
        match v["type"].as_str() {
            Some("result") => {
                let id = v["id"].as_u64().unwrap_or_default();
                if v["success"] == false {
                    tracing::warn!(id, error = %v["error"], "HA request failed");
                    return;
                }
                match id {
                    GET_STATES_ID => {
                        self.entities.clear();
                        for e in v["result"].as_array().into_iter().flatten() {
                            if let Some(eid) = e["entity_id"].as_str().filter(|i| self.relevant(i)) {
                                self.entities.insert(eid.to_string(), e.clone());
                            }
                        }
                        tracing::info!(count = self.entities.len(), "loaded entity states");
                        self.publish(true);
                    }
                    AREAS_ID | DEVICES_ID | ENTITIES_ID => {
                        self.pending.insert(id, v["result"].clone());
                        if self.pending.len() == 3 {
                            self.registry = build_registry(&self.pending);
                            self.pending.clear();
                            tracing::info!(
                                areas = self.registry.area_names.len(),
                                helpers = self.registry.helpers.len(),
                                "loaded registries"
                            );
                            self.publish(true);
                        }
                    }
                    _ => {}
                }
            }
            Some("event") => {
                let data = &v["event"]["data"];
                let Some(id) = data["entity_id"].as_str().filter(|i| self.relevant(i)) else { return };
                let new = &data["new_state"];
                if new.is_null() {
                    self.entities.remove(id);
                } else {
                    self.entities.insert(id.to_string(), new.clone());
                }
                self.publish(true);
            }
            _ => {}
        }
    }
}

fn build_registry(r: &HashMap<u64, Value>) -> view::Registry {
    let list = |id| r.get(&id).and_then(|v| v.as_array()).cloned().unwrap_or_default();
    let area_name: HashMap<String, String> = list(AREAS_ID)
        .iter()
        .filter_map(|a| Some((a["area_id"].as_str()?.to_string(), a["name"].as_str()?.to_string())))
        .collect();
    let device_area: HashMap<String, String> = list(DEVICES_ID)
        .iter()
        .filter_map(|d| Some((d["id"].as_str()?.to_string(), d["area_id"].as_str()?.to_string())))
        .collect();
    let mut reg = view::Registry { area_names: area_name.values().cloned().collect(), ..Default::default() };
    for e in list(ENTITIES_ID) {
        let Some(id) = e["entity_id"].as_str() else { continue };
        if !id.starts_with("light.") && !id.starts_with("switch.") {
            continue;
        }
        let area_id = e["area_id"].as_str().or_else(|| e["device_id"].as_str().and_then(|d| device_area.get(d)).map(String::as_str));
        if let Some(name) = area_id.and_then(|a| area_name.get(a)) {
            reg.area.insert(id.to_string(), name.clone());
        }
        if e["platform"] == "group" {
            reg.helpers.insert(id.to_string());
        }
    }
    reg
}

fn text(v: Value) -> Message {
    Message::Text(v.to_string().into())
}
