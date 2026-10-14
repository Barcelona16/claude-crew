# setup branding — internal (JD) values. make-public.sh swaps in branding.public.sh
# for the open-source build. Sourced by setup.sh; keep it to plain variable + array defs.

TOKEN_PROMPT="Enter your JD llm-gw token: "
TOKEN_DESC="JD gateway token (your own; stays local)"
CCR_TEMPLATE="ccr-config.template.json"
DEFAULT_BACKEND="Claude-Opus-4.8-joybuilder"

# Model presets to generate: "<preset-name>|<provider/realmodel>" per entry.
PRESETS=(
  "Claude-Opus-4.8-joybuilder|opus/Claude-Opus-4.8-joybuilder"
  "GLM-5.2|glm/GLM-5.2"
  "kimi-k3-joybuilder|kimi/kimi-k3-joybuilder"
)
