GOBIN ?= $(shell go env GOPATH)/bin

.PHONY: generate lint build test tools

tools:
	go install google.golang.org/protobuf/cmd/protoc-gen-go@v1.36.12
	go install github.com/bufbuild/buf/cmd/buf@latest

generate:
	PATH="$(GOBIN):$$PATH" buf generate

lint:
	PATH="$(GOBIN):$$PATH" buf lint
	cd helper && go vet ./...

build:
	cd helper && go build -o ../bin/oculuxus-helper ./cmd/oculuxus-helper

test:
	cd helper && go test ./...

.PHONY: app app-test app-run app-bundle

app:
	cd app && swift build

app-test:
	cd app && swift test

app-run:
	cd app && swift run Oculuxus

# dist/Oculuxus.app with the helper inside. ARCHS="arm64" for a quicker
# single-architecture build; the default is universal (arm64 x86_64).
app-bundle:
	app/Bundle/bundle.sh
