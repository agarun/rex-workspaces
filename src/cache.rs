use serde_json::Value;
use std::path::PathBuf;

fn path(name: &str) -> Option<PathBuf> {
    let base = std::env::var_os("XDG_CACHE_HOME")
        .map(PathBuf::from)
        .or_else(|| std::env::var_os("HOME").map(|h| PathBuf::from(h).join(".cache")))?;
    Some(base.join("rex-workspaces").join(name))
}

pub fn load(name: &str) -> Option<Value> {
    let text = std::fs::read_to_string(path(name)?).ok()?;
    serde_json::from_str(&text).ok()
}

pub fn store(name: &str, v: &Value) {
    let Some(path) = path(name) else { return };
    let text = v.to_string();
    if std::fs::read_to_string(&path).is_ok_and(|old| old == text) {
        return;
    }
    if let Some(dir) = path.parent() {
        let _ = std::fs::create_dir_all(dir);
    }
    let tmp = path.with_extension("tmp");
    if std::fs::write(&tmp, text).is_ok() {
        let _ = std::fs::rename(tmp, path);
    }
}
