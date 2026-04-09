# Installation

Get RalphClip's prerequisites installed and verified before doing anything else.

## 1. Fossil SCM

Single binary. No dependencies.

**Linux (Debian/Ubuntu):**
```bash
sudo apt install fossil
```

**Linux (from binary):**
```bash
wget https://fossil-scm.org/home/uv/fossil-linux-x64.tar.gz
tar xzf fossil-linux-x64.tar.gz
sudo mv fossil /usr/local/bin/
```

**macOS:**
```bash
brew install fossil
```

**Verify:**
```bash
fossil version
# Should show: This is fossil version 2.x ...
```

## 2. ooRexx

**Linux (Debian/Ubuntu):**
```bash
# From SourceForge or the ooRexx PPA
sudo apt install oorexx
```

**Linux (from source):**
```bash
wget https://sourceforge.net/projects/oorexx/files/oorexx/5.0.0/ooRexx-5.0.0-src.tar.gz
tar xzf ooRexx-5.0.0-src.tar.gz
cd ooRexx-5.0.0-src
mkdir build && cd build
cmake ..
make -j$(nproc)
sudo make install
```

**macOS:**
```bash
brew install oorexx
```

**Verify:**
```bash
rexx -v
# Should show version info
# Quick test:
rexx -e 'say "ooRexx works"'
```

## 3. AI Runtimes (at least one)

You need at least one AI CLI agent. Install as many as you want — RalphClip uses whichever you configure per agent.

### Claude Code (Anthropic)
```bash
npm install -g @anthropic-ai/claude-code
claude --version
# Log in on first use
```

### Mistral Vibe
```bash
curl -LsSf https://mistral.ai/vibe/install.sh | bash
vibe --setup
# Enter your Mistral API key when prompted
```

### Gemini CLI (Google)
```bash
npx @google/gemini-cli
# Or install globally:
npm install -g @google/gemini-cli
gemini --version
# Log in with Google account for free tier (1,000 requests/day)
```

### Trinity (Arcee AI) — via OpenRouter
```bash
# No CLI binary needed — Trinity is accessed via OpenRouter API.
# Sign up at https://openrouter.ai/ and get an API key.
export OPENROUTER_API_KEY="your-key-here"

# Test it works:
curl -s https://openrouter.ai/api/v1/chat/completions \
  -H "Authorization: Bearer $OPENROUTER_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{"model":"arcee-ai/trinity-mini","messages":[{"role":"user","content":"Hello"}],"max_tokens":50}' \
  | jq '.choices[0].message.content'
```

Available models:
- `trinity-mini` — 26B params, $0.045/$0.15 per M tokens. Fast, cheap.
- `trinity-large-thinking` — 400B params, ~$0.50/$0.90 per M tokens. Frontier reasoning.

Trinity weights are also available on Hugging Face (Apache 2.0) for self-hosting.

## 4. Supporting Tools

These are optional but used by the example script agents:

```bash
# PHP projects (SomeBiz example)
composer require --dev squizlabs/php_codesniffer phpunit/phpunit

# General
sudo apt install jq curl bc   # likely already installed
```

## 5. Verify Everything

Run this to check all prerequisites at once:

```bash
echo "=== RalphClip Prerequisites ==="
echo ""

echo -n "fossil:     "
fossil version 2>/dev/null | head -1 || echo "NOT FOUND"

echo -n "rexx:       "
rexx -e 'say "OK"' 2>/dev/null || echo "NOT FOUND"

echo -n "claude:     "
claude --version 2>/dev/null || echo "not installed (optional)"

echo -n "vibe:       "
vibe --version 2>/dev/null || echo "not installed (optional)"

echo -n "gemini:     "
gemini --version 2>/dev/null || echo "not installed (optional)"

echo -n "trinity:    "
if [ -n "$OPENROUTER_API_KEY" ]; then echo "OpenRouter key set"; else echo "OPENROUTER_API_KEY not set (optional)"; fi

echo ""
echo "Need: fossil + rexx + at least one AI runtime"
```

## 6. Install RalphClip

There's nothing to compile or install. Just unpack and go:

```bash
tar xzf ralphclip.tar.gz
# Put it wherever you like:
mv ralphclip ~/ralphclip
# Or /opt/ralphclip, or anywhere on your system
```

No PATH changes needed — you reference the full path when running:

```bash
rexx ~/ralphclip/orchestrate.rex
bash ~/ralphclip/setup.sh
```

Or add it to PATH if you prefer:

```bash
export RALPHCLIP_HOME=~/ralphclip
export PATH="$RALPHCLIP_HOME:$PATH"
```

## 7. Next Steps

You're ready. Follow the [Tutorial](docs/TUTORIAL.md) to set up your first company:

```bash
mkdir ~/my-company && cd ~/my-company
bash ~/ralphclip/setup.sh

# After setup, verify all configured agents are reachable:
rexx ~/ralphclip/orchestrate.rex --preflight

# Preview what would run (no money spent):
rexx ~/ralphclip/orchestrate.rex --dry-run
```
