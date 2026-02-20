.DEFAULT_GOAL := help

SHELL := /usr/bin/env bash
.SHELLFLAGS := -eu -o pipefail -c

GO ?= go
GOFLAGS ?= -buildvcs=false

ROOT := $(abspath $(CURDIR))
ROOT := $(strip $(ROOT))
BIN_DIR := $(ROOT)/bin
BUILD_DIR := $(ROOT)/build
DATA_DIR := $(ROOT)/.data

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

ifneq ($(words $(ROOT)),1)
$(error ROOT contains spaces or multiple words: [$(ROOT)]. Fix ROOT definition to use $(CURDIR) / Makefile functions only.)
endif

.PHONY: help print-vars build build-qikchain build-qikchaind build-edge clean clean-data fmt test lint \
	genesis-poa genesis-pos genesis-validate allocations-verify \
	up up-poa up-pos down status status-json logs logs-follow \
	reset reset-poa reset-pos doctor

print-vars:
	@echo "ROOT=[$(ROOT)]"
	@echo "BIN_DIR=[$(BIN_DIR)]"
	@echo "BUILD_DIR=[$(BUILD_DIR)]"
	@echo "DATA_DIR=[$(DATA_DIR)]"

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

build-edge:
	@if [ -x "$(POLYGON_EDGE_BIN)" ]; then \
		echo "==> polygon-edge already present at $(POLYGON_EDGE_BIN)"; \
	elif [ -f ./scripts/fetch-polygon-edge.sh ]; then \
		echo "==> Attempting polygon-edge build via scripts/fetch-polygon-edge.sh"; \
		if bash ./scripts/fetch-polygon-edge.sh && [ -d third_party/polygon-edge ]; then \
			cd "$(ROOT)/third_party/polygon-edge" && $(GO) build $(GOFLAGS) -o "$(POLYGON_EDGE_BIN)" .; \
		else \
			echo "==> Warning: polygon-edge fetch/build failed; continuing with qikchain only"; \
		fi; \
	else \
		echo "==> Skipping polygon-edge build (no binary and no fetch script)"; \
	fi

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
	CONSENSUS="$(CONSENSUS)" INSECURE_SECRETS="$(INSECURE_SECRETS)" RESET="$(RESET)" CHAIN_ID="$(CHAIN_ID)" ENV="$(ENV)" POS_DEPLOYMENTS="$(POS_DEPLOYMENTS)" \
		bash "$(DEVNET_UP_SCRIPT)"

up-poa:
	@$(MAKE) up CONSENSUS=poa

up-pos:
	@$(MAKE) up CONSENSUS=pos

down:
	@echo "==> Stopping devnet"
	bash "$(DEVNET_DOWN_SCRIPT)"

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
