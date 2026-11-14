mod app;
mod cache;
mod editor;
mod install;
mod list;
mod picker;
mod rex;
mod spec;
mod theme;
mod widgets;
mod worker;

use app::{App, Start};
use ratatui::crossterm::event::{
    self, DisableMouseCapture, EnableMouseCapture, Event, KeyEventKind, KeyboardEnhancementFlags,
    PopKeyboardEnhancementFlags, PushKeyboardEnhancementFlags,
};
use ratatui::crossterm::execute;
use std::io::stdout;
use std::time::Duration;

const USAGE: &str = "usage: rex-workspaces [COMMAND]

  (none)        open the workspaces window
  edit NAME     open the window on a workspace's form
  new [DIR]     open the window on a new workspace for DIR
  install       link this folder next to Rex's init.lua, add the require line,
                create workspaces.json from the example, and reload Rex
  uninstall     remove the require line and the link; keeps workspaces.json
  path          print the folder that holds the Lua module";

fn start_from_args(args: &[String]) -> Start {
    match args.first().map(String::as_str) {
        Some("edit") if args.len() > 1 => Start::Edit(args[1].clone()),
        Some("new") => {
            let dir = args.get(1).cloned().or_else(|| {
                std::env::current_dir()
                    .ok()
                    .map(|d| d.to_string_lossy().into_owned())
            });
            Start::New(dir.unwrap_or_default())
        }
        _ => Start::List,
    }
}

fn exit_code(result: Result<(), String>) -> i32 {
    match result {
        Ok(()) => 0,
        Err(e) => {
            eprintln!("rex-workspaces: {e}");
            1
        }
    }
}

fn command(args: &[String]) -> Option<i32> {
    match args.first().map(String::as_str) {
        Some("install") => Some(exit_code(install::run())),
        Some("uninstall") => Some(exit_code(install::uninstall())),
        Some("path") => Some(match install::module_dir() {
            Some(dir) => {
                println!("{}", dir.display());
                0
            }
            None => 1,
        }),
        Some("-h" | "--help" | "help") => {
            println!("{USAGE}");
            Some(0)
        }
        Some("-V" | "--version") => {
            println!("rex-workspaces {}", env!("CARGO_PKG_VERSION"));
            Some(0)
        }
        Some("edit" | "new") | None => None,
        Some(other) => {
            eprintln!("rex-workspaces: unknown command: {other}\n\n{USAGE}");
            Some(2)
        }
    }
}

fn main() -> std::io::Result<()> {
    let args: Vec<String> = std::env::args().skip(1).collect();
    if let Some(code) = command(&args) {
        std::process::exit(code);
    }
    let start = start_from_args(&args);
    print!("\x1b[?25l");
    let _ = std::io::Write::flush(&mut stdout());
    theme::detect();
    let mut terminal = ratatui::init();
    let _restore = Restore;
    let flags = PushKeyboardEnhancementFlags(KeyboardEnhancementFlags::DISAMBIGUATE_ESCAPE_CODES);
    execute!(stdout(), EnableMouseCapture, flags)?;
    let mut app = App::new(start);
    while !app.quit {
        app.tick();
        terminal.draw(|f| app.render(f))?;
        if event::poll(Duration::from_millis(150))? {
            match event::read()? {
                Event::Key(k) if k.kind == KeyEventKind::Press => app.key(k),
                Event::Mouse(m) => app.mouse(m),
                _ => {}
            }
        }
    }
    Ok(())
}

struct Restore;

impl Drop for Restore {
    fn drop(&mut self) {
        let _ = execute!(stdout(), PopKeyboardEnhancementFlags, DisableMouseCapture);
        ratatui::restore();
    }
}
