GOLANGCILINT_VERSION ?= 1.50.0
GO_REQUIRED_VERSION ?= 1.19
# Project Setup
PROJECT_NAME := provider-kubernetes
PROJECT_REPO := github.com/crossplane-contrib/$(PROJECT_NAME)

PLATFORMS ?= linux_amd64 linux_arm64

# -include will silently skip missing files, which allows us
# to load those files with a target in the Makefile. If only
# "include" was used, the make command would fail and refuse
# to run a target until the include commands succeeded.
-include build/makelib/common.mk

# ====================================================================================
# Setup XPKG

XPKG_REGISTRY ?= xpkg.upbound.io
XPKG_ORG ?= upbound
XPKG_REPO ?= $(PROJECT_NAME)

# ====================================================================================
# Setup Output

-include build/makelib/output.mk

# ====================================================================================
# Setup Go

# Set a sane default so that the nprocs calculation below is less noisy on the initial
# loading of this file
NPROCS ?= 1

# each of our test suites starts a kube-apiserver and running many test suites in
# parallel can lead to high CPU utilization. by default we reduce the parallelism
# to half the number of CPU cores.
GO_TEST_PARALLEL := $(shell echo $$(( $(NPROCS) / 2 )))

GO_STATIC_PACKAGES = $(GO_PROJECT)/cmd/provider
GO_SUBDIRS += cmd internal apis
GO111MODULE = on
-include build/makelib/golang.mk

# ====================================================================================
# Setup Kubernetes tools
KIND_VERSION = v0.11.1
UP_VERSION = v0.13.0
UP_CHANNEL = stable
USE_HELM3 = true
-include build/makelib/k8s_tools.mk

# ====================================================================================
# Setup Images

IMAGES = provider-kubernetes
-include build/makelib/imagelight.mk

# ====================================================================================
# Setup XPKG

XPKG_REG_ORGS ?= xpkg.upbound.io/crossplane-contrib index.docker.io/crossplanecontrib
# NOTE(hasheddan): skip promoting on xpkg.upbound.io as channel tags are
# inferred.
XPKG_REG_ORGS_NO_PROMOTE ?= xpkg.upbound.io/crossplane-contrib
XPKGS = provider-kubernetes
-include build/makelib/xpkg.mk

# NOTE(hasheddan): we force image building to happen prior to xpkg build so that
# we ensure image is present in daemon.
xpkg.build.provider-kubernetes: do.build.images
# ====================================================================================
# Setup Local Dev
-include build/makelib/local.mk

# ====================================================================================
# Targets

# run `make help` to see the targets and options

# We want submodules to be set up the first time `make` is run.
# We manage the build/ folder and its Makefiles as a submodule.
# The first time `make` is run, the includes of build/*.mk files will
# all fail, and this target will be run. The next time, the default as defined
# by the includes will be run instead.
fallthrough: submodules
	@echo Initial setup complete. Running make again . . .
	@make

# Generate a coverage report for cobertura applying exclusions on
# - generated file
cobertura:
	@cat $(GO_TEST_OUTPUT)/coverage.txt | \
		grep -v zz_generated.deepcopy | \
		$(GOCOVER_COBERTURA) > $(GO_TEST_OUTPUT)/cobertura-coverage.xml

# integration tests
e2e.run: test-integration

local-dev: local.up local.deploy.crossplane

# Run integration tests.
test-integration: $(KIND) $(KUBECTL) $(HELM3)
	@$(INFO) running integration tests using kind $(KIND_VERSION)
	@$(ROOT_DIR)/cluster/integration/integration_tests.sh || $(FAIL)
	@$(OK) integration tests passed

# Update the submodules, such as the common build scripts.
submodules:
	@git submodule sync
	@git submodule update --init --recursive

# NOTE(hasheddan): we must ensure up is installed in tool cache prior to build
# as including the k8s_tools machinery prior to the xpkg machinery sets UP to
# point to tool cache.
build.init: $(UP)

# This is for running out-of-cluster locally, and is for convenience. Running
# this make target will print out the command which was used. For more control,
# try running the binary directly with different arguments.
run: $(KUBECTL) generate
	@$(INFO) Running Crossplane locally out-of-cluster . . .
	@$(KUBECTL) apply -f package/crds/ -R
	go run cmd/provider/main.go -d

manifests:
	@$(INFO) Deprecated. Run make generate instead.

.PHONY: cobertura submodules fallthrough test-integration run manifests

go.cachedir:
	@go env GOCACHE

.PHONY: go.cachedir

go.mod.cachedir:
	@go env GOMODCACHE

.PHONY: go.mod.cachedir

xpkg.build: $(UP) do.build.images
	@$(INFO) Building package $(PROJECT_NAME)-$(VERSION).xpkg for $(PLATFORM)
	@mkdir -p $(OUTPUT_DIR)/xpkg/$(PLATFORM)
	@$(UP) xpkg build  --controller $(BUILD_REGISTRY)/$(PROJECT_NAME)-$(ARCH)  --package-root ./package  --examples-root ./examples  --output ./_output/xpkg/$(PLATFORM)/$(PROJECT_NAME)-$(VERSION).xpkg || $(FAIL)
	@$(OK) Built package $(PROJECT_NAME)-$(VERSION).xpkg for $(PLATFORM)

build.artifacts.platform: xpkg.build


xpkg.push: $(UP)
	@$(INFO) Pushing package $(PROJECT_NAME)-$(VERSION).xpkg
	@$(UP) xpkg push  --package $(OUTPUT_DIR)/xpkg/linux_amd64/$(PROJECT_NAME)-$(VERSION).xpkg  --package $(OUTPUT_DIR)/xpkg/linux_arm64/$(PROJECT_NAME)-$(VERSION).xpkg  $(XPKG_REGISTRY)/$(XPKG_ORG)/$(XPKG_REPO):$(VERSION) || $(FAIL)
	@$(OK) Pushed package $(PROJECT_NAME)-$(VERSION).xpkg


xpkg.load: $(UP)
	@$(INFO) Loading package $(PROJECT_NAME)-$(VERSION).xpkg for $(PLATFORM) into Docker daemon
	@docker load -i $(OUTPUT_DIR)/xpkg/$(PLATFORM)/$(PROJECT_NAME)-$(VERSION).xpkg
	@$(OK) Loaded package $(PROJECT_NAME)-$(VERSION).xpkg for $(PLATFORM) into Docker daemon

