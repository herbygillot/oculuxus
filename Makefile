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

.PHONY: app app-test app-run

app:
	cd app && swift build

app-test:
	cd app && swift test

app-run:
	cd app && swift run Oculuxus
