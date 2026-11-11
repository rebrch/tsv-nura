//! tsv-panel: native Home Assistant wall panel for the Lenovo ThinkSmart View.
//! Slint UI on the main thread; the HA WebSocket client runs on a tokio thread and pushes
//! display snapshots into the UI. Models are updated row by row where the structure is
//! unchanged, so a hold in progress survives unrelated state updates.

mod config;
mod ha;
mod view;

use chrono::Local;
use slint::{ComponentHandle, Model, ModelRc, SharedString, VecModel};
use std::{
    cell::{Cell, RefCell},
    rc::Rc,
    sync::Arc,
    time::{Duration, Instant},
};

slint::include_modules!();

/// A list of sections (Lighting or Plugs page) whose tile models are updated in place
/// while the section titles and sizes stay the same.
#[derive(Default)]
struct SectionModels {
    model: Rc<VecModel<SectionData>>,
    tiles: Vec<Rc<VecModel<TileData>>>,
    shape: Vec<(String, i32)>,
}

impl SectionModels {
    fn sync(&mut self, sections: &[view::Section]) {
        let shape: Vec<(String, i32)> = sections.iter().map(|s| (s.title.clone(), s.height)).collect();
        if shape == self.shape {
            for (model, s) in self.tiles.iter().zip(sections) {
                sync_tiles(model, &s.tiles);
            }
            return;
        }
        self.tiles = sections
            .iter()
            .map(|s| Rc::new(VecModel::from(s.tiles.iter().map(tile_data).collect::<Vec<_>>())))
            .collect();
        self.model.set_vec(
            sections
                .iter()
                .zip(&self.tiles)
                .map(|(s, t)| SectionData { title: s.title.as_str().into(), tiles: ModelRc::from(t.clone()), height: s.height })
                .collect::<Vec<_>>(),
        );
        self.shape = shape;
    }
}

#[derive(Default)]
struct Models {
    home_lights: Rc<VecModel<TileData>>,
    climate: Rc<VecModel<TileData>>,
    lights: SectionModels,
    plugs: SectionModels,
    last: view::Snapshot,
}

thread_local! {
    static MODELS: RefCell<Models> = RefCell::new(Models::default());
}

fn tile_data(t: &view::Tile) -> TileData {
    TileData {
        id: t.id.as_str().into(),
        name: t.name.as_str().into(),
        value: t.value.as_str().into(),
        icon: t.icon.into(),
        on: t.on,
        dead: t.dead,
        tap: t.tap,
        hold: t.hold as i32,
        brightness: t.brightness,
        small: t.small,
        col: t.cell.col,
        span: t.cell.span,
        y: t.cell.y,
        h: t.cell.h,
    }
}

/// Update rows in place when the entity list is unchanged; otherwise replace the contents.
fn sync_tiles(model: &VecModel<TileData>, tiles: &[view::Tile]) {
    let same_shape = model.row_count() == tiles.len()
        && tiles.iter().enumerate().all(|(i, t)| model.row_data(i).is_some_and(|r| r.id == t.id.as_str()));
    if same_shape {
        for (i, t) in tiles.iter().enumerate() {
            let new = tile_data(t);
            if model.row_data(i).as_ref() != Some(&new) {
                model.set_row_data(i, new);
            }
        }
    } else {
        model.set_vec(tiles.iter().map(tile_data).collect::<Vec<_>>());
    }
}

/// Runs on the UI thread.
fn apply(ui: &AppWindow, snap: view::Snapshot) {
    ui.set_connected(snap.connected);
    ui.set_weather_temp(snap.weather_temp.as_str().into());
    ui.set_weather_cond(snap.weather_cond.as_str().into());
    ui.set_weather_icon(snap.weather_icon.into());
    MODELS.with_borrow_mut(|m| {
        sync_tiles(&m.home_lights, &snap.home_lights);
        sync_tiles(&m.climate, &snap.climate);
        m.lights.sync(&snap.light_sections);
        m.plugs.sync(&snap.plug_sections);

        // Keep an open brightness control in step with HA, unless the user is dragging it.
        if ui.get_dimmer_open() && !ui.get_dimmer_dragging() {
            if let Some(t) = snap.find(ui.get_dimmer_id().as_str()) {
                ui.set_dimmer_value(t.brightness);
            }
        }
        m.last = snap;
    });
}

fn main() -> anyhow::Result<()> {
    tracing_subscriber::fmt()
        .with_env_filter(
            tracing_subscriber::EnvFilter::try_from_default_env().unwrap_or_else(|_| "info".into()),
        )
        .without_time() // journald adds timestamps
        .with_ansi(false)
        .init();
    let _ = rustls::crypto::ring::default_provider().install_default();

    let path = std::env::args().nth(1).unwrap_or_else(|| "/etc/tsv-panel/config.toml".into());
    let cfg = Arc::new(config::Config::load(&path)?);

    let ui = AppWindow::new()?;
    ui.set_climate_columns(cfg.home.climate_columns.max(1));
    MODELS.with_borrow(|m| {
        ui.set_home_lights(ModelRc::from(m.home_lights.clone()));
        ui.set_climate(ModelRc::from(m.climate.clone()));
        ui.set_plug_sections(ModelRc::from(m.plugs.model.clone()));
        ui.set_light_sections(ModelRc::from(m.lights.model.clone()));
    });
    apply(&ui, view::build(&cfg, &view::Entities::new(), &view::Registry::default(), false));

    // Clock
    let clock = slint::Timer::default();
    {
        let weak = ui.as_weak();
        let tick = move || {
            if let Some(ui) = weak.upgrade() {
                let now = Local::now();
                ui.set_time(SharedString::from(now.format("%-I:%M").to_string()));
                ui.set_date(SharedString::from(now.format("%A, %B %-d").to_string()));
            }
        };
        tick();
        clock.start(slint::TimerMode::Repeated, Duration::from_secs(1), tick);
    }

    // Idle: sub-pages and the brightness control go back to Home.
    let last_touch = Rc::new(Cell::new(Instant::now()));
    ui.on_interacted({
        let last_touch = last_touch.clone();
        move || last_touch.set(Instant::now())
    });
    let idle = slint::Timer::default();
    {
        let weak = ui.as_weak();
        let limit = Duration::from_secs(cfg.ui.idle_return_seconds);
        idle.start(slint::TimerMode::Repeated, Duration::from_secs(5), move || {
            if let Some(ui) = weak.upgrade()
                && (ui.get_page() != 0 || ui.get_dimmer_open())
                && !ui.get_dimmer_dragging()
                && last_touch.get().elapsed() > limit
            {
                ui.set_dimmer_open(false);
                ui.set_page(0);
            }
        });
    }

    // UI -> HA commands, restricted to lights and configured plugs.
    let (cmd_tx, cmd_rx) = tokio::sync::mpsc::unbounded_channel::<ha::Command>();
    ui.on_activate({
        let (tx, cfg) = (cmd_tx.clone(), cfg.clone());
        move |id| {
            if cfg.may_toggle(&id) {
                let _ = tx.send(ha::Command::Toggle(id.to_string()));
            } else {
                tracing::warn!(%id, "rejected toggle for unconfigured entity");
            }
        }
    });
    ui.on_set_brightness({
        let tx = cmd_tx.clone();
        move |id, pct| {
            if id.starts_with("light.") {
                let _ = tx.send(ha::Command::Brightness(id.to_string(), pct.clamp(0, 100)));
            }
        }
    });
    ui.on_open_dimmer({
        let weak = ui.as_weak();
        move |id| {
            let Some(ui) = weak.upgrade() else { return };
            MODELS.with_borrow(|m| {
                if let Some(t) = m.last.find(id.as_str()).filter(|t| t.hold == view::Hold::Dim) {
                    ui.set_dimmer_id(id.clone());
                    ui.set_dimmer_name(t.name.as_str().into());
                    ui.set_dimmer_value(t.brightness);
                    ui.set_dimmer_open(true);
                }
            });
        }
    });

    // HA client thread
    let weak = ui.as_weak();
    let publish: ha::Publish = Box::new(move |snap| {
        let _ = weak.upgrade_in_event_loop(move |ui| apply(&ui, snap));
    });
    let ha_cfg = cfg.clone();
    std::thread::Builder::new().name("ha".into()).spawn(move || {
        let rt = tokio::runtime::Builder::new_current_thread().enable_all().build().expect("tokio runtime");
        rt.block_on(ha::run(ha_cfg, publish, cmd_rx));
    })?;

    spawn_control_socket(ui.as_weak());

    ui.run()?;
    Ok(())
}

/// Dev/maintenance control socket at $XDG_RUNTIME_DIR/tsv-panel.sock (only the kiosk user and
/// root can reach it: the runtime dir is 0700). One command per connection:
/// `page <0-3>`, `dim <light id>`, `close`.
fn spawn_control_socket(weak: slint::Weak<AppWindow>) {
    use std::io::{BufRead, BufReader, Write};
    let Ok(dir) = std::env::var("XDG_RUNTIME_DIR") else { return };
    let path = std::path::Path::new(&dir).join("tsv-panel.sock");
    let _ = std::fs::remove_file(&path);
    let listener = match std::os::unix::net::UnixListener::bind(&path) {
        Ok(l) => l,
        Err(e) => return tracing::warn!("control socket {}: {e}", path.display()),
    };
    let _ = std::thread::Builder::new().name("control".into()).spawn(move || {
        for mut stream in listener.incoming().flatten() {
            let mut line = String::new();
            if BufReader::new(&stream).read_line(&mut line).is_err() {
                continue;
            }
            let line = line.trim().to_string();
            tracing::info!(cmd = %line, "control");
            let _ = weak.upgrade_in_event_loop(move |ui| {
                let mut parts = line.splitn(2, ' ');
                match (parts.next(), parts.next()) {
                    (Some("page"), Some(p)) => ui.set_page(p.parse().unwrap_or(0)),
                    (Some("dim"), Some(id)) => ui.invoke_open_dimmer(id.into()),
                    (Some("close"), _) => ui.set_dimmer_open(false),
                    _ => {}
                }
                ui.invoke_interacted();
            });
            let _ = stream.write_all(b"ok\n");
        }
    });
}
