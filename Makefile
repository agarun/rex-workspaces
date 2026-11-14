BIN := target/release/rex-workspaces

build:
	cargo build --release

install: build
	$(BIN) install

test: build
	cargo test --release --quiet
	luajit test/unit.lua
	test/e2e.sh

lint:
	stylua --check init.lua lib test/unit.lua
	luacheck -q init.lua lib test/unit.lua
	cargo fmt --check
	cargo clippy --release --all-targets -- -D warnings

.PHONY: build install test lint
