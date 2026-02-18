GO ?= go
GOFLAGS ?= -buildvcs=false

EDGE_REPO=https://github.com/BioMark3r/polygon-edge.git
EDGE_BRANCH=qikchain-base
EDGE_DIR=third_party/polygon-edge
BIN_DIR=bin

.PHONY: all edge qikchain clean

all: edge qikchain

edge:
	./scripts/fetch-polygon-edge.sh
	@set -e; \
	cd third_party/polygon-edge; \
	if ! go build -buildvcs=false -o ../../bin/polygon-edge . ; then \
		echo "edge: build requested go.mod updates; running 'go mod tidy' and retrying..."; \
		go mod tidy; \
		go build -buildvcs=false -o ../../bin/polygon-edge .; \
	fi

qikchain:
	@mkdir -p $(BIN_DIR)
	$(GO) build $(GOFLAGS) -o $(BIN_DIR)/qikchain ./cmd/qikchain

clean:
	rm -rf $(BIN_DIR)
