use serde_json::{json, Value};

pub fn text(spec: &Value, ptr: &str) -> String {
    match spec.pointer(ptr) {
        Some(Value::String(s)) => s.clone(),
        Some(Value::Number(n)) => n.to_string(),
        _ => String::new(),
    }
}

pub fn flag(spec: &Value, ptr: &str, default: bool) -> bool {
    spec.pointer(ptr)
        .and_then(Value::as_bool)
        .unwrap_or(default)
}

pub fn ensure<'a>(spec: &'a mut Value, ptr: &str) -> &'a mut Value {
    let mut cur = spec;
    for seg in ptr.split('/').filter(|s| !s.is_empty()) {
        if !cur.is_object() && !cur.is_array() {
            *cur = json!({});
        }
        cur = match cur {
            Value::Array(items) => {
                let i: usize = seg.parse().unwrap_or(0);
                &mut items[i]
            }
            Value::Object(map) => map.entry(seg.to_string()).or_insert_with(|| json!({})),
            _ => unreachable!(),
        };
    }
    cur
}

pub fn set(spec: &mut Value, ptr: &str, value: Option<Value>) {
    let Some((parent, key)) = ptr.rsplit_once('/') else {
        return;
    };
    let target = ensure(spec, parent);
    if !target.is_object() {
        *target = json!({});
    }
    let map = target.as_object_mut().expect("object");
    match value {
        Some(v) => {
            map.insert(key.to_string(), v);
        }
        None => {
            map.remove(key);
        }
    }
}

pub fn list<'a>(spec: &'a mut Value, ptr: &str) -> &'a mut Vec<Value> {
    let target = ensure(spec, ptr);
    if !target.is_array() {
        *target = json!([]);
    }
    target.as_array_mut().expect("array")
}

pub fn len(spec: &Value, ptr: &str) -> usize {
    spec.pointer(ptr)
        .and_then(Value::as_array)
        .map_or(0, Vec::len)
}

pub fn default_name(name: &str, home: &str, taken: &[String]) -> String {
    let login = home
        .trim_end_matches('/')
        .rsplit('/')
        .next()
        .unwrap_or_default();
    if !name.is_empty() && name != login {
        return name.to_string();
    }
    let mut pick = "untitled".to_string();
    let mut n = 2;
    while taken.contains(&pick) {
        pick = format!("untitled {n}");
        n += 1;
    }
    pick
}

pub fn expand(path: &str, home: &str) -> String {
    if path == "~" {
        return home.to_string();
    }
    match path.strip_prefix("~/") {
        Some(rest) => format!("{home}/{rest}"),
        None => path.to_string(),
    }
}

pub fn contract(path: &str, home: &str) -> String {
    if home.is_empty() {
        return path.to_string();
    }
    if path == home {
        return "~".into();
    }
    match path.strip_prefix(&format!("{home}/")) {
        Some(rest) => format!("~/{rest}"),
        None => path.to_string(),
    }
}
