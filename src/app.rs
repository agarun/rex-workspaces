use crate::cache;
use crate::editor::{Browse, Editor};
use crate::list;
use crate::picker::{self, Picker};
use crate::rex;
use crate::spec;
use crate::theme::{danger, palette};
use crate::widgets::{padded, Hits, Target};
use crate::worker::{self, Done, Job};
use ratatui::crossterm::event::{
    KeyCode, KeyEvent, KeyModifiers, MouseButton, MouseEvent, MouseEventKind,
};
use ratatui::style::Style;
use ratatui::text::Line;
use ratatui::Frame;
use serde_json::{json, Value};
use std::path::PathBuf;
use std::sync::mpsc::{channel, Receiver, Sender};
use std::time::{Duration, Instant};

const REFRESH: Duration = Duration::from_secs(2);
pub enum Start {
    List,
    Edit(String),
    New(String),
    Capture(String),
}

enum Screen {
    List,
    Edit(Box<Editor>),
}

pub struct App {
    pub quit: bool,
    screen: Screen,
    picker: Option<Picker>,
    workspaces: Vec<Value>,
    errors: Vec<String>,
    selected: usize,
    status: Option<(String, bool)>,
    busy: Option<String>,
    home: String,
    hits: Hits,
    hover: Option<Target>,
    pending_edit: Option<String>,
    select_after_list: Option<String>,
    tx: Sender<Done>,
    rx: Receiver<Done>,
    last_list: Option<Instant>,
    listing: bool,
    loaded: bool,
    button_focus: Option<usize>,
    filter: Option<String>,
    hosts: Vec<String>,
    host: Option<String>,
}

impl App {
    pub fn new(start: Start) -> Self {
        let (tx, rx) = channel();
        let mut app = Self {
            quit: false,
            screen: Screen::List,
            picker: None,
            workspaces: Vec::new(),
            errors: Vec::new(),
            selected: 0,
            status: None,
            busy: None,
            home: std::env::var("HOME").unwrap_or_default(),
            hits: Hits::default(),
            hover: None,
            pending_edit: None,
            select_after_list: None,
            tx,
            rx,
            last_list: None,
            listing: false,
            loaded: false,
            button_focus: None,
            filter: None,
            hosts: Vec::new(),
            host: None,
        };
        app.spawn(Job::Hosts);

        match start {
            Start::List => {
                if let Some(v) = cache::load() {
                    app.apply_list(&v);
                }
            }
            Start::Edit(name) => app.pending_edit = Some(name),
            Start::New(dir) => app.new_workspace(dir),
            Start::Capture(session) => app.capture(session),
        }
        app
    }

    fn spawn(&self, job: Job) {
        worker::spawn(&self.tx, self.host.clone(), job);
    }

    fn refresh(&mut self) {
        if !self.listing {
            self.listing = true;
            self.spawn(Job::List);
        }
    }

    pub fn tick(&mut self) {
        while let Ok(done) = self.rx.try_recv() {
            self.handle(done);
        }
        let due = self.last_list.is_none_or(|t| t.elapsed() >= REFRESH);
        if due && matches!(self.screen, Screen::List) {
            self.last_list = Some(Instant::now());
            self.refresh();
        }
    }

    fn current(&self) -> Option<&Value> {
        self.workspaces
            .get(self.selected)
            .filter(|_| self.visible().contains(&self.selected))
    }

    fn selected_name(&self) -> Option<String> {
        self.current()
            .and_then(|w| w["name"].as_str())
            .map(String::from)
    }

    fn visible(&self) -> Vec<usize> {
        let query = self.filter.as_deref().unwrap_or("");
        (0..self.workspaces.len())
            .filter(|&i| list::matches(self.workspaces[i]["name"].as_str().unwrap_or(""), query))
            .collect()
    }

    fn keep_selection_visible(&mut self) {
        let visible = self.visible();
        if !visible.contains(&self.selected) {
            if let Some(&first) = visible.first() {
                self.selected = first;
            }
        }
    }

    fn select(&mut self, name: &str) {
        if let Some(i) = self.workspaces.iter().position(|w| w["name"] == name) {
            self.selected = i;
        }
    }

    fn fail(&mut self, message: String) {
        self.busy = None;
        self.status = Some((message, true));
    }

    fn handle(&mut self, done: Done) {
        match done {
            Done::Hosts(hosts) => self.hosts = hosts,
            Done::List(host, _) if host != self.host => {
                self.listing = false;
                self.last_list = None;
            }
            Done::List(_, result) => {
                self.listing = false;
                match result {
                    Ok(v) => {
                        if self.host.is_none() {
                            cache::store(&v);
                        }
                        self.apply_list(&v);
                        if let Some(name) = self.select_after_list.take() {
                            self.select(&name);
                        }
                        if let Some(name) = self.pending_edit.take() {
                            self.open_editor(&name);
                        }
                    }
                    Err(e) => self.fail(e),
                }
            }
            Done::Verb { verb, name, result } => match result {
                Ok(v) if verb == "open" && v["selected"] == json!(true) => self.quit = true,
                Ok(_) if verb == "open" => {
                    self.busy = None;
                    let hint = "Turn on Remote Control in Rex settings to switch to it from here";
                    self.status = Some((format!("{name} is open. {hint}."), false));
                    self.refresh();
                }
                Ok(v) if verb == "stop" && v["message"].is_string() => {
                    self.busy = None;
                    let message = v["message"].as_str().unwrap_or_default().to_string();
                    let warn = !v["forced"].as_array().is_none_or(Vec::is_empty);
                    self.status = Some((message, warn));
                    self.refresh();
                }
                Ok(_) => {
                    self.busy = None;
                    let past = match verb.as_str() {
                        "stop" => "Stopped",
                        "close" => "Closed",
                        "restart" => "Restarted",
                        _ => "Started",
                    };
                    let on = self.host.as_ref().map(|h| format!(" on {h}"));
                    self.status = Some((format!("{past} {name}{}", on.unwrap_or_default()), false));
                    self.refresh();
                }
                Err(e) => self.fail(e),
            },
            Done::Saved { name, result } => match result {
                Ok(reload) => {
                    if let Screen::Edit(ed) = &mut self.screen {
                        ed.pending = false;
                        ed.previous = Some(name.clone());
                        ed.message = Some(match reload {
                            None => (format!("Saved {name}"), false),
                            Some(e) => (format!("Saved {name}, but Rex did not reload: {e}"), true),
                        });
                    }
                    self.select_after_list = Some(name);
                    self.refresh();
                }
                Err(e) => {
                    if let Screen::Edit(ed) = &mut self.screen {
                        ed.pending = false;
                        ed.message = Some((e, true));
                    }
                }
            },
            Done::Removed { name, result } => match result {
                Ok(reload) => {
                    self.status = Some(match reload {
                        None => (format!("Removed {name}"), false),
                        Some(e) => (format!("Removed {name}, but Rex did not reload: {e}"), true),
                    });
                    self.back_to_list();
                }
                Err(e) => {
                    if let Screen::Edit(ed) = &mut self.screen {
                        ed.pending = false;
                        ed.message = Some((e, true));
                    }
                }
            },
            Done::Captured(result) => match result {
                Ok(v) => {
                    self.busy = None;
                    self.open_capture(&v);
                }
                Err(e) => self.fail(e),
            },
            Done::Detected { root, result } => {
                let home = &self.home;
                let Screen::Edit(ed) = &mut self.screen else {
                    return;
                };
                if root != spec::expand(&non_empty(ed.value("/root"), "~"), home) {
                    return;
                }
                ed.detecting = false;
                let Ok(v) = result else { return };
                ed.detected = v["commands"].as_array().cloned().unwrap_or_default();
                if ed.suggesting {
                    ed.explain_suggestions();
                }
                let empty =
                    spec::len(&ed.spec, "/servers") == 0 && spec::len(&ed.spec, "/tabs") == 0;
                if ed.fresh && empty {
                    if let Some(starter) = v.get("starter").filter(|s| s.is_object()) {
                        ed.spec = starter.clone();
                        ed.message =
                            found_message(spec::len(&ed.spec, "/servers")).map(|m| (m, false));
                    }
                }
                ed.fresh = false;
            }
        }
    }

    fn apply_list(&mut self, v: &Value) {
        self.loaded = true;
        self.workspaces = v["workspaces"].as_array().cloned().unwrap_or_default();
        self.errors = v["errors"]
            .as_array()
            .map(|e| {
                e.iter()
                    .filter_map(|x| x.as_str().map(String::from))
                    .collect()
            })
            .unwrap_or_default();
        if let Some(home) = v["home"].as_str() {
            self.home = home.to_string();
        }
        self.selected = self.selected.min(self.workspaces.len().saturating_sub(1));
        self.keep_selection_visible();
    }

    fn verb(&mut self, verb: &str) {
        let Some(name) = self.selected_name() else {
            return;
        };
        let verb = if self.host.is_some() && verb == "open" {
            "start"
        } else {
            verb
        };
        let running = match verb {
            "open" => "Opening",
            "stop" => "Stopping",
            "close" => "Closing",
            "restart" => "Restarting",
            _ => "Starting",
        };
        self.busy = Some(format!("{running} {name}…"));
        self.status = None;
        self.spawn(Job::Verb {
            verb: verb.into(),
            name,
        });
    }

    fn detect(&self, root: &str, name: &str) {
        let root = spec::expand(if root.is_empty() { "~" } else { root }, &self.home);
        self.spawn(Job::Detect {
            root,
            name: name.into(),
        });
    }

    fn open_editor(&mut self, name: &str) {
        let Some(ws) = self.workspaces.iter().find(|w| w["name"] == name) else {
            self.fail(format!("No workspace named {name}"));
            return;
        };
        let raw = ws["spec"].clone();
        let spec = if raw.is_object() { raw } else { json!({}) };
        let root = spec::text(&spec, "/root");
        self.fit_window("edit");
        self.screen = Screen::Edit(Box::new(Editor::new(name.into(), Some(name.into()), spec)));
        self.detect(&root, name);
    }

    fn names(&self) -> Vec<String> {
        self.workspaces
            .iter()
            .filter_map(|w| w["name"].as_str().map(String::from))
            .collect()
    }

    fn new_workspace(&mut self, dir: String) {
        let base = PathBuf::from(&dir)
            .file_name()
            .map(|n| n.to_string_lossy().into_owned())
            .unwrap_or_default();
        let name = spec::default_name(&base, &self.home, &self.names());
        let spec = json!({ "root": spec::contract(&dir, &self.home) });
        if matches!(self.screen, Screen::List) && self.loaded {
            self.fit_window("edit");
        }
        self.screen = Screen::Edit(Box::new(Editor::new(name.clone(), None, spec)));
        self.detect(&dir, &name);
    }

    fn capture(&mut self, session: String) {
        self.busy = Some("Reading the session…".into());
        self.status = None;
        self.spawn(Job::Capture { session });
    }

    fn open_capture(&mut self, v: &Value) {
        let name = v["name"].as_str().unwrap_or_default().to_string();
        let spec = if v["spec"].is_object() {
            v["spec"].clone()
        } else {
            json!({})
        };
        let root = spec::text(&spec, "/root");
        if matches!(self.screen, Screen::List) && self.loaded {
            self.fit_window("edit");
        }
        let mut ed = Editor::new(name.clone(), None, spec);
        ed.fresh = false;
        ed.message = Some((capture_message(v), false));
        self.screen = Screen::Edit(Box::new(ed));
        self.detect(&root, &name);
    }

    fn save(&mut self) {
        let Screen::Edit(ed) = &mut self.screen else {
            return;
        };
        if ed.pending {
            return;
        }
        if ed.name.trim().is_empty() {
            ed.message = Some(("Give the workspace a name".into(), true));
            return;
        }
        if let Err(e) = ed.normalize_bounds() {
            ed.message = Some((e, true));
            return;
        }
        ed.pending = true;
        ed.message = Some(("Saving…".into(), false));
        let job = Job::Save {
            name: ed.name.trim().into(),
            spec: ed.spec.clone(),
            previous: ed.previous.clone(),
        };
        self.spawn(job);
    }

    fn duplicate(&mut self) {
        let taken = self.names();
        if let Screen::Edit(ed) = &mut self.screen {
            ed.duplicate(&taken);
        }
    }

    fn remove(&mut self) {
        let Screen::Edit(ed) = &mut self.screen else {
            return;
        };
        if ed.pending {
            return;
        }
        let Some(name) = ed.previous.clone() else {
            return;
        };
        if !ed.confirm_remove {
            ed.confirm_remove = true;
            ed.message = Some((
                "Press Remove again to delete it from the file. Its session stays open.".into(),
                true,
            ));
            return;
        }
        ed.pending = true;
        self.spawn(Job::Remove { name });
    }

    fn open_picker(&mut self) {
        let Screen::Edit(ed) = &self.screen else {
            return;
        };
        let Some((ptr, browse)) = ed.browse_target() else {
            return;
        };
        let root = PathBuf::from(spec::expand(&non_empty(ed.value("/root"), "~"), &self.home));
        self.picker = Some(match browse {
            Browse::Root => Picker::open(root, ptr, None),
            Browse::Relative => {
                let current = ed.value(&ptr);
                Picker::open(root.join(current), ptr, Some(root))
            }
        });
    }

    fn pick(&mut self) {
        let Some(picker) = self.picker.take() else {
            return;
        };
        let value = picker.value(&self.home).unwrap_or_default();
        let Screen::Edit(ed) = &mut self.screen else {
            return;
        };
        ed.set_text(&picker.ptr, value.clone(), false);
        if picker.ptr == "/root" {
            if ed.previous.is_none() {
                ed.name = PathBuf::from(&value)
                    .file_name()
                    .map(|n| n.to_string_lossy().into_owned())
                    .unwrap_or_default();
                ed.fresh = true;
                ed.spec = json!({ "root": value });
            }
            ed.detecting = true;
            ed.suggesting = false;
            let name = ed.name.clone();
            self.detect(&value, &name);
        }
    }

    fn back_to_list(&mut self) {
        self.fit_window("list");
        self.screen = Screen::List;
        self.last_list = None;
    }

    fn fit_window(&self, screen: &str) {
        if std::env::var_os("REX_SESSION").is_none() {
            return;
        }
        let before = ratatui::crossterm::terminal::size().ok();
        let resized = rex::resize(screen).is_ok_and(|v| v["resized"] == json!(true));
        if !resized {
            return;
        }
        let deadline = Instant::now() + Duration::from_millis(300);
        while Instant::now() < deadline && ratatui::crossterm::terminal::size().ok() == before {
            std::thread::sleep(Duration::from_millis(10));
        }
    }

    fn list_action(&mut self, action: &str) {
        match action {
            "open" | "start" | "stop" | "restart" | "close" => self.verb(action),
            "edit" => {
                if let Some(name) = self.selected_name() {
                    self.open_editor(&name);
                }
            }
            "new" => {
                let dir = match self.host {
                    Some(_) => self.home.clone(),
                    None => std::env::current_dir()
                        .map(|d| d.to_string_lossy().into_owned())
                        .unwrap_or_default(),
                };
                self.new_workspace(dir);
            }
            "capture" if self.host.is_some() => {
                self.fail("Save as new works only for this pane's host".into())
            }
            "capture" => match std::env::var("REX_SESSION") {
                Ok(session) if !session.is_empty() => self.capture(session),
                _ => self.fail("Open this window in Rex to save a session".into()),
            },
            "filter" => self.filter = Some(self.filter.take().unwrap_or_default()),
            "quit" => self.quit = true,
            _ => {}
        }
    }

    fn list_button(&mut self, i: usize) {
        let buttons = list::buttons(self.current(), !self.workspaces.is_empty());
        if let Some((action, b)) = buttons.get(i) {
            if b.enabled {
                self.list_action(action);
            }
        }
    }

    fn editor_action(&mut self, action: &str) {
        match action {
            "save" => self.save(),
            "cancel" => self.back_to_list(),
            "browse" => self.open_picker(),
            "remove" => self.remove(),
            "duplicate" => self.duplicate(),
            _ => {}
        }
    }

    fn picker_action(&mut self, action: &str) {
        match action {
            "use" => self.pick(),
            "up" => {
                if let Some(p) = &mut self.picker {
                    p.up();
                }
            }
            _ => self.picker = None,
        }
    }

    fn move_selection(&mut self, delta: i32) {
        let visible = self.visible();
        let at = visible
            .iter()
            .position(|&i| i == self.selected)
            .unwrap_or(0);
        let last = visible.len().saturating_sub(1) as i32;
        if let Some(&i) = visible.get((at as i32 + delta).clamp(0, last.max(0)) as usize) {
            self.selected = i;
        }
    }

    fn cycle_button(&mut self, delta: i32) {
        let buttons = list::buttons(self.current(), !self.workspaces.is_empty());
        let n = buttons.len() as i32;
        let default = buttons.iter().position(|(_, b)| b.enabled).unwrap_or(0);
        let mut i = self.button_focus.unwrap_or(default) as i32;
        for _ in 0..n {
            i = (i + delta).rem_euclid(n);
            if buttons[i as usize].1.enabled {
                self.button_focus = Some(i as usize);
                return;
            }
        }
    }

    fn picker_key(&mut self, k: KeyEvent) {
        let Some(p) = &mut self.picker else { return };
        match k.code {
            KeyCode::Up | KeyCode::Char('k') => p.move_by(-1),
            KeyCode::Down | KeyCode::Char('j') => p.move_by(1),
            KeyCode::PageUp => p.move_by(-10),
            KeyCode::PageDown => p.move_by(10),
            KeyCode::Enter | KeyCode::Right | KeyCode::Char('l') => p.enter(p.selected),
            KeyCode::Backspace | KeyCode::Left | KeyCode::Char('h') => p.up(),
            KeyCode::Char(' ') => self.pick(),
            KeyCode::Esc => self.picker = None,
            _ => {}
        }
    }

    fn filter_key(&mut self, k: KeyEvent) -> bool {
        let Some(query) = &mut self.filter else {
            return false;
        };
        let ctrl = k.modifiers.contains(KeyModifiers::CONTROL);
        let on_button = self.button_focus.is_some();
        match k.code {
            KeyCode::Esc if on_button => return false,
            KeyCode::Esc => self.filter = None,
            KeyCode::Backspace if query.is_empty() => self.filter = None,
            KeyCode::Backspace => {
                query.pop();
            }
            KeyCode::Char('u') if ctrl => query.clear(),
            KeyCode::Char(' ') if on_button => return false,
            KeyCode::Char(c) if !ctrl => query.push(c),
            _ => return false,
        }
        self.keep_selection_visible();
        true
    }

    fn list_key(&mut self, k: KeyEvent) {
        if self.filter_key(k) {
            return;
        }
        match k.code {
            KeyCode::Tab | KeyCode::Right => self.cycle_button(1),
            KeyCode::BackTab | KeyCode::Left => self.cycle_button(-1),
            KeyCode::Enter | KeyCode::Char(' ') if self.button_focus.is_some() => {
                let i = self.button_focus.unwrap_or(0);
                self.list_button(i);
            }
            KeyCode::Esc if self.button_focus.is_some() => self.button_focus = None,
            KeyCode::Up | KeyCode::Char('k') => self.move_selection(-1),
            KeyCode::Down | KeyCode::Char('j') => self.move_selection(1),
            KeyCode::Home | KeyCode::Char('g') => self.move_selection(-(i32::MAX / 2)),
            KeyCode::End | KeyCode::Char('G') => self.move_selection(i32::MAX / 2),
            KeyCode::Char('/' | 'f') => self.list_action("filter"),
            KeyCode::Enter | KeyCode::Char('o') => self.list_action("open"),
            KeyCode::Char('s') => self.list_button(1),
            KeyCode::Char('r') => self.list_action("restart"),
            KeyCode::Char('c') => self.list_action("close"),
            KeyCode::Char('e') => self.list_action("edit"),
            KeyCode::Char('n') => self.list_action("new"),
            KeyCode::Char('w') => self.list_action("capture"),
            KeyCode::Char('h') if !self.hosts.is_empty() => self.next_host(),
            KeyCode::Char('q') | KeyCode::Esc => self.quit = true,
            _ => {}
        }
        let enabled = list::buttons(self.current(), !self.workspaces.is_empty());
        if self.button_focus.is_some_and(|i| !enabled[i].1.enabled) {
            self.button_focus = None;
        }
    }

    fn next_host(&mut self) {
        let at = self
            .host
            .as_ref()
            .and_then(|h| self.hosts.iter().position(|x| x == h));
        self.host = match at {
            None => self.hosts.first().cloned(),
            Some(i) => self.hosts.get(i + 1).cloned(),
        };
        self.workspaces.clear();
        self.loaded = false;
        self.selected = 0;
        self.status = None;
        self.busy = None;
        self.button_focus = None;
        self.last_list = None;
    }

    fn editor_key(&mut self, k: KeyEvent) {
        let ctrl = k.modifiers.contains(KeyModifiers::CONTROL);
        let alt = k.modifiers.contains(KeyModifiers::ALT);
        let Screen::Edit(ed) = &mut self.screen else {
            return;
        };
        ed.confirm_remove = false;
        ed.message = None;
        if ed.recording {
            ed.record(k);
            return;
        }
        let text = ed.focused_is_text();
        match k.code {
            KeyCode::Char('s') if ctrl => self.save(),
            KeyCode::Char('o') if ctrl => self.open_picker(),
            KeyCode::Char('d') if ctrl => self.duplicate(),
            KeyCode::Char('x') if ctrl => ed.remove_focused(),
            KeyCode::Char('u') if ctrl => ed.clear(),
            KeyCode::Char('w') if ctrl => ed.delete_word(),
            KeyCode::Backspace if alt || ctrl => ed.delete_word(),
            KeyCode::Char('a') if ctrl => ed.cursor_home(),
            KeyCode::Char('e') if ctrl => ed.cursor_end(),
            KeyCode::Esc => self.back_to_list(),
            KeyCode::Up | KeyCode::BackTab => ed.focus_row(-1),
            KeyCode::Down | KeyCode::Tab => ed.focus_row(1),
            KeyCode::PageUp => (0..10).for_each(|_| ed.focus_row(-1)),
            KeyCode::PageDown => (0..10).for_each(|_| ed.focus_row(1)),
            KeyCode::Left => ed.move_cursor(-1),
            KeyCode::Right => ed.move_cursor(1),
            KeyCode::Home => ed.cursor_home(),
            KeyCode::End => ed.cursor_end(),
            KeyCode::Backspace => ed.backspace(),
            KeyCode::Delete => ed.delete(),
            KeyCode::Enter => {
                if ed.activate() {
                    self.open_picker();
                }
            }
            KeyCode::Char(' ') if !text => {
                if ed.activate() {
                    self.open_picker();
                }
            }
            KeyCode::Char(c) if !ctrl => ed.type_char(c),
            _ => {}
        }
    }

    pub fn key(&mut self, k: KeyEvent) {
        if k.modifiers.contains(KeyModifiers::CONTROL) && k.code == KeyCode::Char('c') {
            self.quit = true;
            return;
        }
        if self.picker.is_some() {
            self.picker_key(k);
        } else if matches!(self.screen, Screen::List) {
            self.list_key(k);
        } else {
            self.editor_key(k);
        }
    }

    pub fn mouse(&mut self, m: MouseEvent) {
        let target = self.hits.at(m.column, m.row);
        match m.kind {
            MouseEventKind::Moved => self.hover = target,
            MouseEventKind::ScrollUp => self.scroll(-1),
            MouseEventKind::ScrollDown => self.scroll(1),
            MouseEventKind::Down(MouseButton::Left) => {
                if let Some(t) = target {
                    self.click(t);
                }
            }
            _ => {}
        }
    }

    fn scroll(&mut self, delta: i32) {
        if let Some(p) = &mut self.picker {
            p.move_by(delta);
            return;
        }
        match &mut self.screen {
            Screen::List => self.move_selection(delta),
            Screen::Edit(ed) => ed.focus_row(delta),
        }
    }

    fn click(&mut self, target: Target) {
        if let Some(p) = &mut self.picker {
            match target {
                Target::PickerRow(i) => p.enter(i),
                Target::Button(i) => self.picker_action(picker::BUTTONS[i]),
                _ => {}
            }
            return;
        }
        match (&mut self.screen, target) {
            (Screen::List, Target::Row(i)) => {
                self.selected = i;
                self.button_focus = None;
            }
            (Screen::List, Target::Button(i)) => self.list_button(i),
            (Screen::Edit(ed), Target::Row(i)) => {
                ed.focus_at(i);
                ed.recording = ed.on_shortcut();
                if !ed.focused_is_text() && ed.activate() {
                    self.open_picker();
                }
            }
            (Screen::Edit(ed), Target::Browse(i)) => {
                ed.focus_at(i);
                self.open_picker();
            }
            (Screen::Edit(ed), Target::Side(i)) => ed.side(i),
            (Screen::Edit(ed), Target::Button(i)) => {
                if let Some((action, _)) = ed.buttons().get(i) {
                    self.editor_action(action);
                }
            }
            _ => {}
        }
    }

    fn status_line(&self) -> Option<Line<'static>> {
        let p = palette();
        if let Some(b) = &self.busy {
            return Some(Line::styled(b.clone(), Style::new().fg(p.warning)));
        }
        if let Some((m, error)) = &self.status {
            let style = if *error {
                danger()
            } else {
                Style::new().fg(p.success)
            };
            return Some(Line::styled(m.clone(), style));
        }
        self.errors
            .first()
            .map(|e| Line::styled(format!("Config: {e}"), danger()))
    }

    pub fn render(&mut self, f: &mut Frame) {
        self.hits.clear();
        let inner = padded(f.area());
        let status = self.status_line();
        match &mut self.screen {
            Screen::List => {
                let visible = self.visible();
                let view = list::View {
                    workspaces: &self.workspaces,
                    visible: &visible,
                    loaded: self.loaded,
                    filter: self.filter.as_deref(),
                    selected: self.selected,
                    home: &self.home,
                    status,
                    button_focus: self.button_focus,
                    hosts: &self.hosts,
                    host: self.host.as_deref(),
                };
                list::render(f, inner, view, &mut self.hits, self.hover);
            }
            Screen::Edit(ed) => ed.render(f, inner, &mut self.hits, self.hover),
        }
        if let Some(p) = &self.picker {
            p.render(f, &mut self.hits, self.hover, &self.home);
        }
    }
}

fn found_message(found: usize) -> Option<String> {
    match found {
        0 => None,
        1 => Some("Found 1 dev server. Check it, then save.".into()),
        n => Some(format!("Found {n} dev servers. Check them, then save.")),
    }
}

fn capture_message(v: &Value) -> String {
    let notes: Vec<&str> = v["notes"]
        .as_array()
        .map(|n| n.iter().filter_map(Value::as_str).collect())
        .unwrap_or_default();
    if notes.is_empty() {
        "Check the name, tabs and panes, then save.".into()
    } else {
        notes.join(" ")
    }
}

fn non_empty(s: String, fallback: &str) -> String {
    if s.is_empty() {
        fallback.to_string()
    } else {
        s
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn found_message_only_when_something_was_found() {
        assert_eq!(found_message(0), None);
        assert_eq!(
            found_message(1).as_deref(),
            Some("Found 1 dev server. Check it, then save.")
        );
        assert_eq!(
            found_message(3).as_deref(),
            Some("Found 3 dev servers. Check them, then save.")
        );
    }

    #[test]
    fn capture_message_joins_notes() {
        let v = json!({ "notes": ["One.", "Two."] });
        assert_eq!(capture_message(&v), "One. Two.");
        assert_eq!(
            capture_message(&json!({})),
            "Check the name, tabs and panes, then save."
        );
    }
}
