SHELL := bash
COMPOSE := docker compose -f test/compose.yaml
DISTROS := ubuntu arch

# Fresh secrets for each make invocation. The canary stands in for the real
# model provider key: tests check that no user can ever read it.
LITELLM_MASTER_KEY := $(or $(LITELLM_MASTER_KEY),sk-master-$(shell openssl rand -hex 16))
ONBEHALF_CANARY    := $(or $(ONBEHALF_CANARY),sk-canary-$(shell openssl rand -hex 16))
FORGEJO_ADMIN_PASSWORD := $(or $(FORGEJO_ADMIN_PASSWORD),$(shell openssl rand -hex 16))
export LITELLM_MASTER_KEY ONBEHALF_CANARY FORGEJO_ADMIN_PASSWORD

.PHONY: demo site site-assets images rebuild lint lint-shell lint-docker lint-yaml lint-docs test $(addprefix test-,$(DISTROS)) $(addprefix shell-,$(DISTROS)) down

# Static checks; the same ones CI runs. Needs shellcheck, shfmt, hadolint, yamllint.
# lint-docs needs only bash and awk.
SHELL_FILES = bin/onbehalf $(shell git ls-files '*.sh')

lint: lint-shell lint-docker lint-yaml lint-docs

lint-shell:
	@files="$(SHELL_FILES)"; \
	for f in $$files; do bash -n $$f || exit 1; done; \
	shellcheck -x -S warning $$files && shfmt -d $$files

lint-docker:
	hadolint test/images/*.Dockerfile demo/images/*.Dockerfile .clusterfuzzlite/Dockerfile

lint-yaml:
	yamllint .

# ASD-STE100 and terminology checks for the files in test/lint/ste-files.txt.
lint-docs:
	test/lint-docs.sh

# GitHub Pages site. The images come from docs/assets. The build uses the
# same image as actions/jekyll-build-pages. DRAFTS=1 also builds the posts
# with "published: false", with plain Jekyll in the same image.
# The image version comes from the workflow, so Dependabot updates both.
PAGES_IMAGE := ghcr.io/actions/jekyll-build-pages:$(shell sed -n 's/.*jekyll-build-pages@[0-9a-f]* \# //p' .github/workflows/pages.yml)
SITE_ASSETS := docs/assets/banner.svg docs/assets/architecture.svg docs/assets/social-preview.png \
  $(addprefix docs/assets/demo/,user.webm user.gif)
# Rootless Docker maps root in the container to you; other Docker needs -u.
SITE_USER = $(shell docker info -f '{{.SecurityOptions}}' 2>/dev/null | grep -q rootless || echo "-u $$(id -u):$$(id -g)")

site-assets:
	mkdir -p site/assets/demo
	cp $(filter-out docs/assets/demo/%,$(SITE_ASSETS)) site/assets/
	cp $(filter docs/assets/demo/%,$(SITE_ASSETS)) site/assets/demo/

site: site-assets
	docker run --rm $(SITE_USER) -v "$$PWD/site:/src" -w /usr/local/bundle \
	  -e JEKYLL_ENV=production -e PAGES_REPO_NWO=Neverdecel/onbehalf -e HOME=/tmp \
	  --entrypoint bin/$(if $(DRAFTS),jekyll,github-pages) $(PAGES_IMAGE) \
	  build --source /src --destination /src/_site $(if $(DRAFTS),--unpublished)

# Cached build: layers are reused until a Dockerfile or version pin changes.
images:
	$(COMPOSE) build

# Clean build: pull base images again and ignore the layer cache.
rebuild:
	$(COMPOSE) build --pull --no-cache

test: $(addprefix test-,$(DISTROS))

# Each run: fresh gateway + database + host container, removed afterwards.
$(addprefix test-,$(DISTROS)): test-%:
	@$(COMPOSE) build host-$* && $(COMPOSE) up -d --wait gateway forgejo || exit 1; \
	$(COMPOSE) run --rm host-$* /src/test/run.sh; rc=$$?; \
	$(COMPOSE) down -v --remove-orphans; exit $$rc

# Interactive root shell in a fresh host container, for development.
$(addprefix shell-,$(DISTROS)): shell-%:
	@$(COMPOSE) build host-$* && $(COMPOSE) up -d --wait gateway forgejo || exit 1; \
	$(COMPOSE) run --rm host-$* bash -l; \
	$(COMPOSE) down -v --remove-orphans

down:
	$(COMPOSE) down -v --remove-orphans

# Recorded casts of the operator and the user, in docs/assets/demo. Each run
# starts from a clean host. The tapes run in order, because each one continues
# from the state of the last one. See demo/README.md.
DEMO := docker compose -f demo/compose.yaml
DEMO_TAPES := operator-setup user operator-report

demo:
	@$(DEMO) --profile base build host-ubuntu && $(DEMO) --profile record build devbox vhs || exit 1; \
	mkdir -p docs/assets/demo; \
	$(DEMO) down -v --remove-orphans; $(DEMO) up -d --wait devbox || exit 1; rc=0; \
	for t in $(DEMO_TAPES); do $(DEMO) --profile record run --rm -T vhs /demo/$$t.tape >demo/.$$t.log 2>&1 \
	  && ! grep -q 'recording failed' demo/.$$t.log || { echo "FAIL $$t (see demo/.$$t.log)"; rc=1; break; }; echo "ok   $$t"; done; \
	$(DEMO) down -v --remove-orphans; exit $$rc
