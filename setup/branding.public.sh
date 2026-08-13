# setup branding — open-source defaults. Points at the generic placeholder CCR template
# and generic preset names. Users edit ~/.claude-code-router/config.json + these presets
# to wire their own official APIs (Anthropic / OpenAI / etc). Sourced by setup.sh.

TOKEN_PROMPT="Enter your LLM gateway / API token: "
TOKEN_DESC="API token (your own; stays local)"
# the generic placeholder CCR template (make-public.sh renames the .public template to this
# canonical name in the build, so setup.sh reads the same filename in both versions).
CCR_TEMPLATE="ccr-config.template.json"
DEFAULT_BACKEND="default"

# Generic starter presets. The template ships __PROVIDER__/__MODEL__ placeholders; edit
# ~/.claude-code-router/config.json + these .conf files to match your real providers.
PRESETS=(
  "default|__PROVIDER__,__MODEL__"
)
