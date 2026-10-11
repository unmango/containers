SYSTEM ?= $(shell nix eval --raw --impure --expr builtins.currentSystem)
META := .\#legacyPackages.$(SYSTEM).imageMeta
IMAGES ?= $(shell nix eval --json --apply builtins.attrNames '$(META)' | jq -r 'join(" ")')

REGISTRY ?= ghcr.io/unmango

build:
	nix build .#

build-%:
	nix build .#$*

load-%:
	nix run .#$*.copyToDockerDaemon

# The repository comes from imageName rather than the stem, so variants of one
# application share a repository and differ only by tag.
push-%:
	nix run .#$*.copyTo -- \
		"docker://$(REGISTRY)/$(shell nix eval --raw '$(META).$*.imageName'):$(shell nix eval --raw '$(META).$*.imageTag')"

# UniFi OS Server is unfree: its images are never built in CI or published
# publicly. This pushes one to a private repository; see
# images/unifi-os-server/default.nix.
UOS := .\#legacyPackages.$(SYSTEM).unifi-os-server

push-uos-%:
	nix run '$(UOS).$*.copyTo' -- \
		"docker://$(REGISTRY)/$(shell nix eval --raw '$(UOS).$*.imageName'):$(shell nix eval --raw '$(UOS).$*.imageTag')"

manifests: $(patsubst images/%/base.nix,manifest-%,$(wildcard images/*/base.nix))

manifest-%:
	./scripts/update-manifest.sh $*

list:
	@printf '%s\n' $(IMAGES)

meta:
	@nix eval --json '$(META)' | jq

update:
	nix flake update

check lint:
	nix flake check

format fmt:
	nix fmt

.PHONY: build manifests list meta update check lint format fmt
