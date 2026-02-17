EDGE_REPO=https://github.com/BioMark3r/polygon-edge.git
EDGE_BRANCH=qikchain-base
EDGE_DIR=third_party/polygon-edge
BIN_DIR=bin

.PHONY: all edge qikchain clean

all: edge qikchain

edge:
	@mkdir -p $(EDGE_DIR)
	@if [ ! -d "$(EDGE_DIR)/.git" ]; then \
		git clone --branch $(EDGE_BRANCH) $(EDGE_REPO) $(EDGE_DIR); \
	fi
	cd $(EDGE_DIR) && go build -o ../../$(BIN_DIR)/polygon-edge ./...

qikchain:
	@mkdir -p $(BIN_DIR)
	go build -o $(BIN_DIR)/qikchain ./cmd/qikchain

clean:
	rm -rf $(BIN_DIR)
