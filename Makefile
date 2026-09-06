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

manifests: $(IMAGES:%=manifest-%)

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
