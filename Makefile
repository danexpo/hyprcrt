# hyprcrt - the gate, in one word. Mirrors .github/workflows/build.yml so a piece is green here
# before CI sees it. GPU compiles and the live behaviour are proved in tests/run-nested.sh.
SH_FILES  = bin/hyprcrt tools/crt-build tools/crt-fetch omarchy-plugin/hooks/hyprcrt-rebuild tests/run-nested.sh tests/run-loader-test.sh
LUA_FILES = lua/loader.lua omarchy-plugin/bindings.lua contrib/hyprland/hyprcrt.lua tests/nested.lua tests/loader-test.lua
GATE_OUT  = tests/out/gate

.PHONY: gate plugin shaders shell lua json qml shadercheck clean

gate: plugin shaders shell lua json qml
	@echo "gate: green - plugin built, four presets generate, shell/lua/json/qml checks passed"

plugin:
	$(MAKE) -C plugin all

# the four presets through crt-gen, each a valid GLES 3.00 shader (the GPU compile runs in the nested session)
shaders:
	@mkdir -p $(GATE_OUT)
	@for p in plain scanlines monitor television; do \
	  tools/crt-gen presets/$$p.conf pitch=3 > $(GATE_OUT)/$$p.frag || exit 1; \
	  head -1 $(GATE_OUT)/$$p.frag | grep -q '#version 300 es' || { echo "shaders: $$p.frag has no GLES header"; exit 1; }; \
	done
	@echo "shaders: four presets generate"

shell:
	@command -v shellcheck >/dev/null || { echo "gate: shellcheck is not installed (sudo pacman -S shellcheck)"; exit 1; }
	shellcheck -S warning -e SC1091,SC2016 $(SH_FILES)

lua:
	@for f in $(LUA_FILES); do luac -p $$f || exit 1; done
	@echo "lua: $(words $(LUA_FILES)) files parse"

json:
	@jq -e '.schemaVersion == 1 and (.id | startswith("omarchy.") | not)' manifest.json >/dev/null
	@python3 -c "import re,json; [json.loads(re.sub(r'^\s*//.*$$','',open(f).read(),flags=re.M)) for f in ('omarchy-plugin/menu.jsonc','contrib/waybar/hyprcrt.jsonc')]"
	@echo "json: manifest and jsonc parse"

# syntax only, as in CI: the qs.* modules come from omarchy-shell
qml:
	@if command -v qmllint >/dev/null; then for f in omarchy-plugin/*.qml; do qmllint --no-unqualified-id -i $$f 2>/dev/null || true; done; echo "qml: linted"; \
	else echo "qml: qmllint not installed, skipped (CI runs it)"; fi

# the offscreen shader runner, for rendering docs/previews (see README)
shadercheck: tests/shadercheck
tests/shadercheck: tests/shadercheck.c
	gcc -O2 $< -o $@ $$(pkg-config --cflags --libs egl glesv2 gbm) -lm

clean:
	$(MAKE) -C plugin clean
	rm -rf $(GATE_OUT) tests/shadercheck
