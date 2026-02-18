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
	cd third_party/polygon-edge && go build -buildvcs=false -o ../../bin/polygon-edge .

qikchain:
	@mkdir -p $(BIN_DIR)
	$(GO) build $(GOFLAGS) -o $(BIN_DIR)/qikchain ./cmd/qikchain

clean:
	rm -rf $(BIN_DIR)
