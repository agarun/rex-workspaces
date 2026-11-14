use std::fs;
use std::io::Write;
use std::os::unix::fs::symlink;
use std::path::{Path, PathBuf};
use std::process::Command;

const NAME: &str = "rex-workspaces";
const REQUIRE: &str = "require(\"rex-workspaces\").setup{}";
pub fn module_dir() -> Option<PathBuf> {
    if let Some(dir) = std::env::var_os("REX_WORKSPACES_DIR") {
        return Some(dir.into());
    }
    let exe = std::env::current_exe().ok()?.canonicalize().ok()?;
    let dir = exe
        .ancestors()
        .skip(1)
        .find(|d| d.join("init.lua").is_file() && d.join("lib/lifecycle.lua").is_file())?;
    Some(stable(dir))
}
fn stable(dir: &Path) -> PathBuf {
    let text = dir.to_string_lossy();
    let marker = format!("/Cellar/{NAME}/");
    if let Some(i) = text.find(&marker) {
        let rest = &text[i + marker.len()..];
        if let Some(j) = rest.find('/') {
            let opt = PathBuf::from(format!("{}/opt/{NAME}{}", &text[..i], &rest[j..]));
            if opt.exists() {
                return opt;
            }
        }
    }
    dir.to_path_buf()
}

fn config_dir() -> PathBuf {
    let base = std::env::var_os("XDG_CONFIG_HOME")
        .map(PathBuf::from)
        .unwrap_or_else(|| {
            PathBuf::from(std::env::var_os("HOME").unwrap_or_default()).join(".config")
        });
    base.join("rex")
}

fn same(a: &Path, b: &Path) -> bool {
    matches!((a.canonicalize(), b.canonicalize()), (Ok(x), Ok(y)) if x == y)
}

fn link(module: &Path, conf: &Path) -> Result<(), String> {
    let at = conf.join(NAME);
    if same(&at, module) {
        return Ok(());
    }
    match fs::symlink_metadata(&at) {
        Ok(m) if m.file_type().is_symlink() => fs::remove_file(&at).map_err(|e| e.to_string())?,
        Ok(_) => {
            return Err(format!(
                "{} exists and is not a link to {}; move it away and run install again",
                at.display(),
                module.display()
            ))
        }
        Err(_) => {}
    }
    symlink(module, &at).map_err(|e| format!("cannot link {}: {e}", at.display()))?;
    println!("Linked {} -> {}", at.display(), module.display());
    Ok(())
}

fn add_require(conf: &Path) -> Result<(), String> {
    let init = conf.join("init.lua");
    let text = fs::read_to_string(&init).unwrap_or_default();
    if text.contains("\"rex-workspaces\"") {
        return Ok(());
    }
    let mut file = fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(&init)
        .map_err(|e| format!("cannot open {}: {e}", init.display()))?;
    writeln!(file, "\n{REQUIRE}").map_err(|e| e.to_string())?;
    println!("Added {REQUIRE} to {}", init.display());
    Ok(())
}

fn add_example(module: &Path, conf: &Path) -> Result<(), String> {
    let file = conf.join("workspaces.json");
    if file.exists() {
        return Ok(());
    }
    fs::copy(module.join("examples/workspaces.json"), &file).map_err(|e| e.to_string())?;
    println!("Created {} with a my-project demo", file.display());
    Ok(())
}

fn rex(args: &[&str]) -> Result<(), String> {
    let out = Command::new("rex")
        .args(args)
        .output()
        .map_err(|e| format!("cannot run rex: {e}"))?;
    if out.status.success() {
        return Ok(());
    }
    Err(String::from_utf8_lossy(&out.stderr).trim().to_string())
}

pub fn run() -> Result<(), String> {
    let module =
        module_dir().ok_or("cannot find init.lua next to this binary; set REX_WORKSPACES_DIR")?;
    let conf = config_dir();
    fs::create_dir_all(&conf).map_err(|e| e.to_string())?;
    link(&module, &conf)?;
    add_require(&conf)?;
    add_example(&module, &conf)?;
    rex(&["config", "check"])?;
    rex(&["config", "reload"])?;
    println!("Done. Press Cmd+O in Rex, or run: rex do workspace_list");
    Ok(())
}

fn unlink(conf: &Path) -> Result<(), String> {
    let at = conf.join(NAME);
    let Ok(meta) = fs::symlink_metadata(&at) else {
        return Ok(());
    };
    if meta.file_type().is_symlink() {
        fs::remove_file(&at).map_err(|e| format!("cannot remove {}: {e}", at.display()))?;
    } else if module_dir().is_some_and(|m| same(&m, &at)) {
        fs::remove_dir_all(&at).map_err(|e| format!("cannot remove {}: {e}", at.display()))?;
    } else {
        return Err(format!(
            "{} is not a rex-workspaces install; remove it yourself",
            at.display()
        ));
    }
    println!("Removed {}", at.display());
    Ok(())
}

fn remove_require(conf: &Path) -> Result<(), String> {
    let init = conf.join("init.lua");
    let Ok(text) = fs::read_to_string(&init) else {
        return Ok(());
    };
    let kept: Vec<&str> = text.lines().filter(|l| l.trim() != REQUIRE).collect();
    if kept.len() == text.lines().count() {
        if text.contains("\"rex-workspaces\"") {
            eprintln!(
                "{} still requires rex-workspaces; remove that line",
                init.display()
            );
        }
        return Ok(());
    }
    let mut out = kept.join("\n").trim_end().to_string();
    out.push('\n');
    fs::write(&init, out).map_err(|e| format!("cannot write {}: {e}", init.display()))?;
    println!("Removed {REQUIRE} from {}", init.display());
    Ok(())
}

pub fn uninstall() -> Result<(), String> {
    let conf = config_dir();
    remove_require(&conf)?;
    unlink(&conf)?;
    if rex(&["config", "reload"]).is_err() {
        eprintln!("Could not reload Rex; restart it to finish");
    }
    println!("Kept {}", conf.join("workspaces.json").display());
    Ok(())
}
