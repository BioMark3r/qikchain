.DEFAULT_GOAL := help

SHELL := /usr/bin/env bash
.SHELLFLAGS := -eu -o pipefail -c

GO ?= go
GOFLAGS ?= -buildvcs=false

MAKEFILE_DIR := $(abspath $(dir $(lastword $(MAKEFILE_LIST))))
ROOT := $(patsubst %/,%,$(MAKEFILE_DIR))
ROOT := $(strip $(ROOT))
BIN_DIR := $(ROOT)/bin
BUILD_DIR := $(ROOT)/build
DATA_DIR := $(ROOT)/.data
UI_DIR := apps/status-ui
UI_STATE_DIR := $(DATA_DIR)/status-ui
UI_PID := $(UI_STATE_DIR)/status-ui.pid
UI_LOG := $(UI_STATE_DIR)/status-ui.log

BUILD_TARGETS := build-qikchain
ifneq ($(wildcard cmd/qikchaind),)
BUILD_TARGETS += build-qikchaind
endif

QIKCHAIN_BIN := $(BIN_DIR)/qikchain
QIKCHAIND_BIN := $(BIN_DIR)/qikchaind
POLYGON_EDGE_BIN := $(BIN_DIR)/polygon-edge

DEVNET_UP_SCRIPT ?= ./scripts/devnet-ibft4.sh
DEVNET_DOWN_SCRIPT ?= ./scripts/devnet-ibft4-stop.sh
DEVNET_STATUS_SCRIPT := $(if $(wildcard ./scripts/devnet-ibft4-status.sh),./scripts/devnet-ibft4-status.sh,./scripts/devnet-ibft4-status)

CONSENSUS ?= poa
INSECURE_SECRETS ?= 1
RESET ?= 0
CHAIN_ID ?= 100
ENV ?= devnet
POS_DEPLOYMENTS ?= build/deployments/pos.local.json
ALLOCATIONS_FILE ?= config/allocations/$(ENV).json

# Guard against ROOT being accidentally duplicated into multiple absolute paths
ifneq ($(words $(ROOT)),1)
$(error ROOT appears malformed (multiple absolute paths detected): [$(ROOT)])
endif


.PHONY: help print-vars build build-qikchain build-txhelper build-qikchaind build-edge clean clean-data fmt test lint \
	genesis-poa genesis-pos genesis-validate allocations-verify \
	up up-poa up-pos down status status-json logs logs-follow \
	reset reset-poa reset-pos doctor docker-devnet-up docker-devnet-down docker-devnet-logs release-local \
	status-ui status-ui-logs status-ui-status stop-ui up-with-ui

print-vars:
	@printf 'ROOT=[%s]\n' '$(ROOT)'
	@printf 'BIN_DIR=[%s]\n' '$(BIN_DIR)'
	@printf 'BUILD_DIR=[%s]\n' '$(BUILD_DIR)'
	@printf 'DATA_DIR=[%s]\n' '$(DATA_DIR)'
	@printf 'CURDIR=[%s]\n' '$(CURDIR)'

help:
	@echo "QikChain developer Make targets"
	@echo ""
	@echo "Core:"
	@echo "  make build            Build ./bin/qikchain, ./bin/qikchaind (and polygon-edge if available)"
	@echo "  make clean            Remove build artifacts (set RESET=1 to also wipe .data/ibft4)"
	@echo "  make clean-data       Remove .data/ibft4"
	@echo "  make fmt              Format Go code"
	@echo "  make test             Run Go tests"
	@echo "  make lint             Run go vet"
	@echo "  make release-local    Build release tarballs + SHA256SUMS into dist/"
	@echo ""
	@echo "Genesis:"
	@echo "  make genesis-poa      Build PoA genesis artifacts"
	@echo "  make genesis-pos      Build PoS genesis artifacts (uses POS_DEPLOYMENTS)"
	@echo "  make genesis-validate Validate build/chain.json"
	@echo "  make allocations-verify Verify devnet allocations"
	@echo ""
	@echo "Devnet:"
	@echo "  make up               Start devnet (defaults CONSENSUS=poa)"
	@echo "  make up-poa           Start PoA devnet"
	@echo "  make up-pos           Start PoS devnet"
	@echo "  make down             Stop devnet"
	@echo "  make status           Human-readable status"
	@echo "  make status-json      JSON status (pretty-printed with jq when installed)"
	@echo "  make logs             Tail recent logs (LOGS=1)"
	@echo "  make logs-follow      Stream logs (LOGS=1 FOLLOW=1)"
	@echo "  make docker-devnet-up   Start Docker devnet via docker compose"
	@echo "  make docker-devnet-down Stop Docker devnet (set RESET=1 to remove volumes)"
	@echo "  make docker-devnet-logs Follow Docker devnet logs"
	@echo "  make status-ui        Install and run the status UI in background (default: HOST=0.0.0.0 PORT=8787)"
	@echo "  make status-ui-logs   Tail status UI logs"
	@echo "  make status-ui-status Check status UI pid/process state"
	@echo "  make stop-ui          Stop status UI background process"
	@echo "  make up-with-ui       Start devnet in background, then run status UI"
	@echo ""
	@echo "Convenience:"
	@echo "  make reset            down + wipe data + up"
	@echo "  make reset-poa        down + wipe data + up-poa"
	@echo "  make reset-pos        down + wipe data + up-pos"
	@echo "  make doctor           Show binary versions and listeners"
	@echo ""
	@echo "Common environment variables:"
	@echo "  CONSENSUS=$(CONSENSUS)          # poa|pos"
	@echo "  INSECURE_SECRETS=$(INSECURE_SECRETS)   # dev-only; do NOT use in production"
	@echo "  RESET=$(RESET)                  # set to 1 to wipe .data/ibft4 in clean/up flows"
	@echo "  CHAIN_ID=$(CHAIN_ID)"
	@echo "  ENV=$(ENV)"
	@echo "  POS_DEPLOYMENTS=$(POS_DEPLOYMENTS)"
	@echo ""
	@echo "Examples:"
	@echo "  make up"
	@echo "  make reset-poa"
	@echo "  make status-json"
	@echo ""
	@echo "Notes:"
	@echo "  - INSECURE_SECRETS is for local/dev usage only."
	@echo "  - Polygon Edge metrics flag is --prometheus; startup script already handles compatibility."

build: $(BUILD_TARGETS) build-edge

build-qikchain:
	@echo "==> Building qikchain"
	@mkdir -p "$(BIN_DIR)"
	$(GO) build $(GOFLAGS) -o "$(QIKCHAIN_BIN)" ./cmd/qikchain

build-qikchaind:
	@echo "==> Building qikchaind"
	@mkdir -p "$(BIN_DIR)"
	$(GO) build $(GOFLAGS) -o "$(QIKCHAIND_BIN)" ./cmd/qikchaind

build-txhelper:
	@echo "==> Building txhelper"
	@mkdir -p "$(BIN_DIR)"
	$(GO) build $(GOFLAGS) -o "$(BIN_DIR)/txhelper" ./cmd/txhelper

REQUIRE_EDGE ?= 0
EDGE_DIR := $(ROOT)/third_party/polygon-edge

build-edge:
	@bash -eu -o pipefail -c '\
		echo "==> build-edge"; \
		if [ -x "$(POLYGON_EDGE_BIN)" ]; then \
			echo "==> polygon-edge already present at $(POLYGON_EDGE_BIN)"; \
			exit 0; \
		fi; \
		if [ -f "./scripts/fetch-polygon-edge.sh" ]; then \
			echo "==> Fetching polygon-edge via scripts/fetch-polygon-edge.sh"; \
			bash ./scripts/fetch-polygon-edge.sh; \
		else \
			echo "==> Skipping polygon-edge build (no binary and no fetch script)"; \
			exit 0; \
		fi; \
		if [ ! -d "$(EDGE_DIR)" ]; then \
			echo "==> Warning: polygon-edge dir not found at $(EDGE_DIR)"; \
			if [ "$(REQUIRE_EDGE)" = "1" ]; then exit 1; else exit 0; fi; \
		fi; \
		echo "==> Building polygon-edge (go build -mod=mod)"; \
		set +e; \
		( cd "$(EDGE_DIR)" && $(GO) build -mod=mod $(GOFLAGS) -o "$(POLYGON_EDGE_BIN)" . ); \
		rc=$$?; \
		set -e; \
		if [ $$rc -ne 0 ]; then \
			echo "==> Warning: polygon-edge build failed (rc=$$rc)"; \
			if [ "$(REQUIRE_EDGE)" = "1" ]; then exit $$rc; else exit 0; fi; \
		fi; \
		echo "==> polygon-edge built: $(POLYGON_EDGE_BIN)"; \
	'

release-local:
	@echo "==> Building local release artifacts"
	bash ./scripts/release/build.sh

clean:
	@echo "==> Cleaning build artifacts"
	@rm -rf "$(BUILD_DIR)"
	@if [ "$(RESET)" = "1" ]; then \
		echo "==> RESET=1, removing $(DATA_DIR)/ibft4"; \
		rm -rf "$(DATA_DIR)/ibft4"; \
	fi

clean-data:
	@echo "==> Removing $(DATA_DIR)/ibft4"
	@rm -rf "$(DATA_DIR)/ibft4"

fmt:
	@echo "==> Formatting Go code"
	@gofmt -w $$(find . -type f -name '*.go' -not -path './third_party/*')

test:
	@echo "==> Running tests"
	$(GO) test ./...

lint:
	@echo "==> Running go vet"
	$(GO) vet ./...

genesis-poa: build-qikchain
	@echo "==> Building PoA genesis artifacts"
	"$(QIKCHAIN_BIN)" genesis build \
		--consensus poa \
		--env $(ENV) \
		--chain-id $(CHAIN_ID) \
		--out-chain "$(BUILD_DIR)/chain.json" \
		--out-genesis "$(BUILD_DIR)/genesis-eth.json"

genesis-pos: build-qikchain
	@echo "==> Building PoS genesis artifacts"
	"$(QIKCHAIN_BIN)" genesis build \
		--consensus pos \
		--env $(ENV) \
		--chain-id $(CHAIN_ID) \
		--pos-deployments "$(POS_DEPLOYMENTS)" \
		--out-chain "$(BUILD_DIR)/chain.json" \
		--out-genesis "$(BUILD_DIR)/genesis-eth.json"

genesis-validate: build-qikchain
	@echo "==> Validating $(BUILD_DIR)/chain.json"
	"$(QIKCHAIN_BIN)" genesis validate --chain "$(BUILD_DIR)/chain.json"

allocations-verify: build-qikchain
	@echo "==> Verifying allocations for $(ENV)"
	"$(QIKCHAIN_BIN)" allocations verify --file "$(ALLOCATIONS_FILE)"

up: build
	@echo "==> Starting devnet (CONSENSUS=$(CONSENSUS))"
	@if [ "$(RESET)" = "1" ]; then \
		echo "RESET=1 detected — wiping previous chain data."; \
	fi
	CONSENSUS="$(CONSENSUS)" INSECURE_SECRETS="$(INSECURE_SECRETS)" RESET="$(RESET)" CHAIN_ID="$(CHAIN_ID)" ENV="$(ENV)" POS_DEPLOYMENTS="$(POS_DEPLOYMENTS)" \
		bash "$(DEVNET_UP_SCRIPT)"

up-poa:
	@$(MAKE) up CONSENSUS=poa

up-pos:
	@$(MAKE) up CONSENSUS=pos

down:
	@echo "==> Stopping devnet"
	bash "$(DEVNET_DOWN_SCRIPT)"

docker-devnet-up:
	@echo "==> Starting Docker devnet"
	docker compose up --build -d

docker-devnet-down:
	@echo "==> Stopping Docker devnet"
	@if [ "$(RESET)" = "1" ]; then \
		docker compose down -v; \
	else \
		docker compose down; \
	fi

docker-devnet-logs:
	@echo "==> Following Docker devnet logs"
	docker compose logs -f

status:
	@echo "==> Devnet status"
	bash "$(DEVNET_STATUS_SCRIPT)"

status-json:
	@echo "==> Devnet status (JSON)"
	@if JSON=1 bash "$(DEVNET_STATUS_SCRIPT)" > /tmp/qikchain-status.json 2>/tmp/qikchain-status.err; then \
		if command -v jq >/dev/null 2>&1; then \
			jq . /tmp/qikchain-status.json; \
		else \
			echo "jq not found; printing raw JSON"; \
			cat /tmp/qikchain-status.json; \
		fi; \
	else \
		echo "status script failed; emitting fallback JSON"; \
		msg=$$(tr '\n' ' ' </tmp/qikchain-status.err | sed 's/"/\\"/g'); \
		echo "{\"ok\":false,\"error\":\"$$msg\"}"; \
	fi

logs:
	@echo "==> Recent devnet logs"
	LOGS=1 bash "$(DEVNET_STATUS_SCRIPT)"

status-ui:
	@echo "==> Starting status UI in background"
	@mkdir -p "$(UI_STATE_DIR)"
	@host="$${HOST:-0.0.0.0}"; \
	port="$${PORT:-8787}"; \
	api_base="http://127.0.0.1:$$port"; \
	if [ -f "$(UI_PID)" ]; then \
		pid=$$(cat "$(UI_PID)"); \
		if kill -0 "$$pid" >/dev/null 2>&1; then \
			echo "status-ui already running (pid=$$pid)"; \
			echo "Loopback URL: $$api_base"; \
			echo "PID file: $(UI_PID)"; \
			echo "Log file: $(UI_LOG)"; \
			exit 0; \
		fi; \
		echo "Removing stale PID file: $(UI_PID)"; \
		rm -f "$(UI_PID)"; \
	fi; \
	if [ -f "$(UI_DIR)/package-lock.json" ]; then \
		npm --prefix "$(UI_DIR)" ci; \
	else \
		npm --prefix "$(UI_DIR)" install; \
	fi; \
	(cd "$(UI_DIR)" && nohup env HOST="$$host" PORT="$$port" node server.js >>"$(UI_LOG)" 2>&1 & echo $$! >"$(UI_PID)"); \
	sleep 1; \
	pid=$$(cat "$(UI_PID)" 2>/dev/null || true); \
	echo "UI running (pid $$pid)"; \
	echo "Loopback URL: http://127.0.0.1:$$port"; \
	status_json=$$(curl -fsS "$$api_base/api/status" 2>/dev/null || true); \
	if [ -n "$$status_json" ]; then \
		ips=$$(printf '%s' "$$status_json" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("localIP") or ""); print(d.get("publicIP") or "")' 2>/dev/null || true); \
		local_ip=$$(printf '%s\n' "$$ips" | sed -n '1p'); \
		public_ip=$$(printf '%s\n' "$$ips" | sed -n '2p'); \
		if [ -n "$$local_ip" ]; then \
			echo "Local URL:  http://$$local_ip:$$port"; \
		fi; \
		if [ -n "$$public_ip" ]; then \
			echo "Public URL: http://$$public_ip:$$port"; \
		fi; \
	else \
		echo "Could not fetch $$api_base/api/status yet. Check logs: $(UI_LOG)"; \
	fi; \
	echo "Log file: $(UI_LOG)"

status-ui-logs:
	@if [ ! -f "$(UI_LOG)" ]; then \
		echo "status-ui log file not found: $(UI_LOG)"; \
		exit 1; \
	fi; \
	tail -f "$(UI_LOG)"

status-ui-status:
	@if [ ! -f "$(UI_PID)" ]; then \
		echo "status-ui is not running (missing $(UI_PID))"; \
		exit 0; \
	fi; \
	pid=$$(cat "$(UI_PID)"); \
	if kill -0 "$$pid" >/dev/null 2>&1; then \
		echo "status-ui is running (pid=$$pid)"; \
		echo "Log file: $(UI_LOG)"; \
	else \
		echo "status-ui pid file exists but process $$pid is not running"; \
	fi

stop-ui:
	@echo "==> Stopping status UI"
	@if [ ! -f "$(UI_PID)" ]; then \
		echo "status-ui is not running (missing $(UI_PID))"; \
		exit 0; \
	fi; \
	pid=$$(cat "$(UI_PID)"); \
	if kill -0 "$$pid" >/dev/null 2>&1; then \
		kill "$$pid"; \
		i=0; \
		while kill -0 "$$pid" >/dev/null 2>&1 && [ $$i -lt 30 ]; do \
			sleep 0.1; \
			i=$$((i + 1)); \
		done; \
		if kill -0 "$$pid" >/dev/null 2>&1; then \
			echo "status-ui did not stop in time; sending SIGKILL to $$pid"; \
			kill -9 "$$pid" >/dev/null 2>&1 || true; \
		fi; \
		echo "stopped status-ui (pid=$$pid)"; \
	else \
		echo "status-ui process $$pid not running"; \
	fi; \
	rm -f "$(UI_PID)"

up-with-ui:
	@echo "==> Starting devnet in background"
	@$(MAKE) up >/tmp/qikchain-up.log 2>&1 &
	@echo "==> Devnet logs: /tmp/qikchain-up.log"
	@$(MAKE) status-ui

logs-follow:
	@echo "==> Following devnet logs"
	LOGS=1 FOLLOW=1 bash "$(DEVNET_STATUS_SCRIPT)"

reset:
	@$(MAKE) down || true
	@$(MAKE) clean-data
	@$(MAKE) up

reset-poa:
	@$(MAKE) down || true
	@$(MAKE) clean-data
	@$(MAKE) up-poa

reset-pos:
	@$(MAKE) down || true
	@$(MAKE) clean-data
	@$(MAKE) up-pos

doctor: build
	@echo "==> QikChain doctor"
	@echo "ROOT: $(ROOT)"
	@echo "BIN_DIR: $(BIN_DIR)"
	@echo "qikchain bin: $(QIKCHAIN_BIN)"
	@echo "qikchaind bin: $(QIKCHAIND_BIN)"
	@echo "polygon-edge bin: $(POLYGON_EDGE_BIN)"
	@echo "devnet up script: $(DEVNET_UP_SCRIPT)"
	@echo "devnet status script: $(DEVNET_STATUS_SCRIPT)"
	@ls -la "$(BIN_DIR)"
	@echo ""
	@echo "-- Versions --"
	@if [ -x "$(QIKCHAIN_BIN)" ]; then "$(QIKCHAIN_BIN)" --help >/dev/null 2>&1 && echo "qikchain: present"; else echo "qikchain: missing"; fi
	@if [ -x "$(QIKCHAIND_BIN)" ]; then "$(QIKCHAIND_BIN)" --help >/dev/null 2>&1 && echo "qikchaind: present"; else echo "qikchaind: missing"; fi
	@if [ -x "$(POLYGON_EDGE_BIN)" ]; then "$(POLYGON_EDGE_BIN)" version 2>/dev/null || "$(POLYGON_EDGE_BIN)" --version 2>/dev/null || echo "polygon-edge: present"; else echo "polygon-edge: missing"; fi
	@echo ""
	@echo "-- Listener check (known devnet ports) --"
	@if command -v ss >/dev/null 2>&1; then \
		ss -ltnp | awk '$$4 ~ /:(8545|8546|8547|8548|9632|9633|9634|9635|1478|1479|1480|1481|9090|9091|9092|9093)$$/'; \
	elif command -v lsof >/dev/null 2>&1; then \
		lsof -nPiTCP -sTCP:LISTEN | awk '$$9 ~ /:(8545|8546|8547|8548|9632|9633|9634|9635|1478|1479|1480|1481|9090|9091|9092|9093)$$/'; \
	else \
		echo "Neither ss nor lsof is available."; \
	fi
