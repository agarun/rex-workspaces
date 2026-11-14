use crate::rex;
use serde_json::Value;
use std::sync::mpsc::Sender;
use std::thread;

pub enum Job {
    Hosts,
    List,
    Verb {
        verb: String,
        name: String,
    },
    Save {
        name: String,
        spec: Value,
        previous: Option<String>,
    },
    Remove {
        name: String,
    },
    Detect {
        root: String,
        name: String,
    },
    Capture {
        session: String,
    },
}

pub enum Done {
    Hosts(Vec<String>),
    List(Option<String>, Result<Value, String>),
    Verb {
        verb: String,
        name: String,
        result: Result<Value, String>,
    },
    Saved {
        name: String,
        result: Result<Option<String>, String>,
    },
    Removed {
        name: String,
        result: Result<Option<String>, String>,
    },
    Detected {
        root: String,
        result: Result<Value, String>,
    },
    Captured(Result<Value, String>),
}

fn reloaded(host: Option<&str>, result: Result<Value, String>) -> Result<Option<String>, String> {
    result?;
    Ok(rex::reload(host).err())
}

fn run(host: Option<String>, job: Job) -> Done {
    let h = host.as_deref();
    match job {
        Job::Hosts => Done::Hosts(rex::plugin_hosts()),
        Job::List => Done::List(host.clone(), rex::list(h)),
        Job::Verb { verb, name } => {
            let result = rex::verb(h, &verb, &name);
            Done::Verb { verb, name, result }
        }
        Job::Save {
            name,
            spec,
            previous,
        } => {
            let result = reloaded(h, rex::save(h, &name, &spec, previous.as_deref()));
            Done::Saved { name, result }
        }
        Job::Remove { name } => {
            let result = reloaded(h, rex::remove(h, &name));
            Done::Removed { name, result }
        }
        Job::Detect { root, name } => {
            let result = rex::detect(h, &root, &name);
            Done::Detected { root, result }
        }
        Job::Capture { session } => Done::Captured(rex::capture(h, &session)),
    }
}

pub fn spawn(tx: &Sender<Done>, host: Option<String>, job: Job) {
    let tx = tx.clone();
    thread::spawn(move || {
        let _ = tx.send(run(host, job));
    });
}
