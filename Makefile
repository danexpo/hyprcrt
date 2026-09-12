# hyprcrt - the gate, in one word. Mirrors .github/workflows/build.yml so a piece is green here
# before CI sees it. GPU compiles and the live behaviour are proved in tests/run-nested.sh.
SH_FILES  = bin/hyprcrt tools/crt-build tools/crt-fetch omarchy-plugin/hooks/hyprcrt-rebuild tests/run-nested.sh tests/run-loader-test.sh tests/shadergate tests/run-cli-test.sh tests/lib-nested.sh tests/run-install-test.sh tests/presetcheck tools/crt-presets tests/run-damage-test.sh tests/run-capture-test.sh tests/uniformcheck tools/crt-previews
LUA_FILES = lua/loader.lua omarchy-plugin/bindings.lua tests/nested.lua tests/loader-test.lua
GATE_OUT  = tests/out/gate
# Arch ships qmllint outside PATH, in /usr/lib/qt6/bin
QMLLINT  ?= $(or $(shell command -v qmllint 2>/dev/null),$(wildcard /usr/lib/qt6/bin/qmllint))
# syntax and everything else qmllint checks, minus what needs omarchy-shell's qs.* modules to resolve
QMLLINT_FLAGS = --import disable --unresolved-type disable --unqualified disable --required disable --signal-handler-parameters disable -W 0

.PHONY: gate plugin shaders presets uniforms cli install-test shell lua json qml shadercheck previews bench clean

gate: plugin shaders presets uniforms cli install-test shell lua json qml
	@echo "gate: green - plugin built, every shader compiles, the preset tables agree with presets/*.conf, Chain.cpp's uniform names agree with the passes, the CLI refuses bad values, the README's install works on a clean HOME, shell/lua/json/qml checks passed"

plugin:
	$(MAKE) -C plugin all

# the preset numbers in bin/hyprcrt and plugin/src/Look.hpp are hand copies of presets/*.conf: they must agree
presets:
	tests/presetcheck

# every shader either mode loads must compile: the four presets (crt-gen) and the seven plugin passes,
# through glslangValidator and, where /dev/dri exists, the GPU (tests/shadercheck)
shaders:
	tests/shadergate $(GATE_OUT)

# every m_<pass>.loc("name") in Chain.cpp names a uniform its own pass .frag declares - glUniform* on the -1
# a silently-wrong name returns is a no-op, so a rename on one side would otherwise drop an effect with no error
uniforms:
	tests/uniformcheck

# bin/hyprcrt's lite path in a sandboxed HOME (never the live session): what `set` refuses and stores
cli:
	tests/run-cli-test.sh

# the README's plain-Hyprland install on a clean HOME, from a local stand-in for the prebuilt release: files, time,
# the checksum refusal (needs the library `plugin` builds)
install-test: plugin
	tests/run-install-test.sh

shell:
	@command -v shellcheck >/dev/null || { echo "gate: shellcheck is not installed (sudo pacman -S shellcheck)"; exit 1; }
	shellcheck -S warning -e SC1091,SC2016 $(SH_FILES)

lua:
	@for f in $(LUA_FILES); do luac -p $$f || exit 1; done
	@echo "lua: $(words $(LUA_FILES)) files parse"

json:
	@jq -e '.schemaVersion == 1 and (.id | startswith("omarchy.") | not)' manifest.json >/dev/null
	@python3 -c "import re,json; [json.loads(re.sub(r'^\s*//.*$$','',open(f).read(),flags=re.M)) for f in ('omarchy-plugin/menu.jsonc',)]"
	@echo "json: manifest and jsonc parse"

# a syntax error fails; unresolved qs.* names do not (those modules come from omarchy-shell). CI always runs it.
qml:
	@if [ -n "$(QMLLINT)" ]; then for f in omarchy-plugin/*.qml; do $(QMLLINT) $(QMLLINT_FLAGS) $$f || exit 1; done; echo "qml: linted"; \
	else echo "qml: qmllint not installed, skipped (CI runs it)"; fi

# the offscreen GPU cost table in docs/perf.md: one resolution after the other, never in parallel (needs /dev/dri)
BENCH_SIZES ?= 3440x1440 3840x2160
bench: bench/bench
	@for r in $(BENCH_SIZES); do bench/bench $${r%x*} $${r#*x} || exit 1; done
bench/bench: bench/bench.c
	gcc -O2 $< -o $@ $$(pkg-config --cflags --libs egl glesv2 gbm) -lm

# the README's images, re-rendered from docs/previews/source.png and text_source.png (needs /dev/dri
# and ImageMagick). Deterministic: after a run with no shader change, `git diff docs/previews` is empty.
previews: tests/shadercheck
	tools/crt-previews

# the offscreen shader runner, for rendering docs/previews (see README)
shadercheck: tests/shadercheck
tests/shadercheck: tests/shadercheck.c
	gcc -O2 $< -o $@ $$(pkg-config --cflags --libs egl glesv2 gbm) -lm

clean:
	$(MAKE) -C plugin clean
	rm -rf $(GATE_OUT) tests/shadercheck bench/bench
