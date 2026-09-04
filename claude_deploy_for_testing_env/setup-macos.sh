#!/bin/bash
#
# MoneyMarket - Claude Desktop MCP setup for macOS
#
# Keep this file in the same folder as mcp-connect-tool.mjs, then run:
#
#   chmod +x setup-macos.sh
#   ./setup-macos.sh
#
# Optional arguments:
#   ./setup-macos.sh --email you@moneymarket.gr --key YOUR_CONNECTION_KEY
#   ./setup-macos.sh --skip-atlassian-login
#   ./setup-macos.sh --skip-aws-credentials --skip-atlassian-login
#
# The M365 connection key and any cloud credentials are secrets. Prefer the
# interactive prompts so they do not remain in your shell history.

set -u
set -o pipefail

if [[ -t 1 ]]; then
  CYAN=$'\033[36m'
  GREEN=$'\033[32m'
  YELLOW=$'\033[33m'
  RED=$'\033[31m'
  GRAY=$'\033[90m'
  RESET=$'\033[0m'
else
  CYAN=''; GREEN=''; YELLOW=''; RED=''; GRAY=''; RESET=''
fi

info()    { printf '%s\n' "$*"; }
heading() { printf '%s== %s ==%s\n' "$CYAN" "$*" "$RESET"; }
ok()      { printf '%s[OK]%s %s\n' "$GREEN" "$RESET" "$*"; }
warn()    { printf '%s[!]%s %s\n' "$YELLOW" "$RESET" "$*"; }
fail()    { printf '%s[X]%s %s\n' "$RED" "$RESET" "$*" >&2; }
skip()    { printf '[--] %s\n' "$*"; }

trim_ws() {
  local value=${1-}
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s' "$value"
}

json_field() {
  local field=$1
  "$node_bin" -e '
    let data = "";
    process.stdin.setEncoding("utf8");
    process.stdin.on("data", chunk => data += chunk);
    process.stdin.on("end", () => {
      try {
        const object = JSON.parse(data);
        const value = field.split(".").reduce((v, k) => v == null ? undefined : v[k], object);
        if (value !== undefined && value !== null) process.stdout.write(String(value));
      } catch (_) {
        process.exitCode = 2;
      }
    });
    const field = process.argv[1];
  ' "$field"
}

usage() {
  cat <<'EOF'
Usage: ./setup-macos.sh [options]

Options:
  --email EMAIL                 Microsoft 365 email for mcp-365
  --key KEY                     Personal mcp-365 connection key
  --skip-atlassian-login        Defer Jira/Confluence OAuth until first use
  --aws-access-key-id ID        AWS access key for the Bedrock profile
  --aws-secret-access-key KEY   AWS secret access key
  --aws-session-token TOKEN     Required when using an ASIA temporary key
  --skip-aws-credentials        Leave ~/.aws/credentials unchanged
  --big-query-key VALUE         GCP JSON path or PEM private key
  --skip-big-query              Do not configure BigQuery
  -h, --help                    Show this help
EOF
}

email=''
connection_key=''
skip_atlassian=0
aws_access_key_id=''
aws_secret_access_key=''
aws_session_token=''
skip_aws=0
bigquery_key=''
skip_bigquery=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --email|-Email)
      [[ $# -ge 2 ]] || { fail "$1 needs a value."; exit 2; }
      email=$2; shift 2 ;;
    --key|-Key)
      [[ $# -ge 2 ]] || { fail "$1 needs a value."; exit 2; }
      connection_key=$2; shift 2 ;;
    --skip-atlassian-login|-SkipAtlassianLogin)
      skip_atlassian=1; shift ;;
    --aws-access-key-id|-AwsAccessKeyId)
      [[ $# -ge 2 ]] || { fail "$1 needs a value."; exit 2; }
      aws_access_key_id=$2; shift 2 ;;
    --aws-secret-access-key|-AwsSecretAccessKey)
      [[ $# -ge 2 ]] || { fail "$1 needs a value."; exit 2; }
      aws_secret_access_key=$2; shift 2 ;;
    --aws-session-token|-AwsSessionToken)
      [[ $# -ge 2 ]] || { fail "$1 needs a value."; exit 2; }
      aws_session_token=$2; shift 2 ;;
    --skip-aws-credentials|-SkipAwsCredentials)
      skip_aws=1; shift ;;
    --big-query-key|-BigQueryKey)
      [[ $# -ge 2 ]] || { fail "$1 needs a value."; exit 2; }
      bigquery_key=$2; shift 2 ;;
    --skip-big-query|-SkipBigQuery)
      skip_bigquery=1; shift ;;
    -h|--help)
      usage; exit 0 ;;
    --)
      shift; break ;;
    *)
      fail "Unknown option: $1"
      usage >&2
      exit 2 ;;
  esac
done

script_dir=$(cd "$(dirname "$0")" && pwd -P)
heading "MoneyMarket - Claude Desktop MCP setup (macOS)"

# 1) Node.js is needed for mcp-connect, mcp-remote, and safe JSON handling.
node_bin=$(command -v node 2>/dev/null || true)
npx_bin=$(command -v npx 2>/dev/null || true)
if [[ -z "$node_bin" || -z "$npx_bin" ]]; then
  fail "Node.js or npx was not found on PATH."
  info "    Install Node.js LTS from https://nodejs.org, reopen Terminal, and rerun this script."
  exit 1
fi
ok "Node $("$node_bin" --version), npx present"

# The PowerShell installer depends on this companion file too. Check before
# starting any browser sign-in so a missing package file fails immediately.
source_tool="$script_dir/mcp-connect-tool.mjs"
if [[ ! -f "$source_tool" ]]; then
  fail "mcp-connect-tool.mjs is missing."
  info "    Put it in the same folder as setup-macos.sh, then rerun the script."
  exit 1
fi

# 2) Microsoft 365 identity and personal connection key.
if [[ -z "$email" ]]; then
  read -r -p "Enter your Microsoft 365 email (for mcp-365): " email
fi
email=$(trim_ws "$email")
if [[ ! "$email" =~ ^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$ ]]; then
  fail "'$email' does not look like a valid email."
  exit 1
fi

mcp_host='internal-mcp.insurancemarket.gr'
mcp_remote_version='0.8.2'
has_key=0
connection_key=$(trim_ws "$connection_key")

if [[ -n "$connection_key" ]]; then
  if [[ ! "$connection_key" =~ ^[0-9a-fA-F]{32,}$ ]]; then
    fail "That does not look like a connection key (expected a long hex string)."
    exit 1
  fi
  has_key=1
  ok "Using the connection key you supplied."
else
  info ""
  heading "Microsoft 365 sign-in"
  info "You will sign in now so this script can collect your connection key."
  info "Your password goes only to Microsoft; this Mac stores the returned connection key."
  info ""

  auth_base="https://${mcp_host}:3004"
  request_body=$("$node_bin" -e 'process.stdout.write(JSON.stringify({email: process.argv[1]}))' "$email")
  curl_error=$(mktemp "${TMPDIR:-/tmp}/mm-auth-error.XXXXXX")
  if ! start_json=$(curl -fsS --max-time 45 -X POST \
      -H 'Content-Type: application/json' \
      --data "$request_body" "$auth_base/api/auth/start" 2>"$curl_error"); then
    fail "Could not reach the sign-in service at $auth_base"
    sed 's/^/    /' "$curl_error" >&2
    info "    Are you on the company network or VPN? $mcp_host is internal-only."
    rm -f "$curl_error"
    exit 1
  fi
  rm -f "$curl_error"

  start_success=$(printf '%s' "$start_json" | json_field success || true)
  if [[ "$start_success" != 'true' ]]; then
    start_error=$(printf '%s' "$start_json" | json_field error || true)
    fail "Sign-in could not be started: ${start_error:-unknown error}"
    exit 1
  fi

  verification_uri=$(printf '%s' "$start_json" | json_field verificationUri || true)
  user_code=$(printf '%s' "$start_json" | json_field userCode || true)
  info "  1. A browser is opening at: $verification_uri"
  printf '  2. Enter this code: %s%s%s\n' "$YELLOW" "$user_code" "$RESET"
  info "  3. Sign in as $email and approve the permissions."
  info ""
  if ! open "$verification_uri" 2>/dev/null; then
    info "  (The browser could not open automatically; open the URL above yourself.)"
  fi
  printf '%sWaiting for you to finish signing in...%s\n' "$GRAY" "$RESET"

  curl_error=$(mktemp "${TMPDIR:-/tmp}/mm-auth-error.XXXXXX")
  if ! done_json=$(curl -fsS --max-time 600 -X POST \
      -H 'Content-Type: application/json' \
      --data "$request_body" "$auth_base/api/auth/complete" 2>"$curl_error"); then
    fail "Sign-in did not complete."
    sed 's/^/    /' "$curl_error" >&2
    rm -f "$curl_error"
    info "    Rerun this script to try again."
    exit 1
  fi
  rm -f "$curl_error"

  done_success=$(printf '%s' "$done_json" | json_field success || true)
  connection_key=$(printf '%s' "$done_json" | json_field connectionKey || true)
  if [[ "$done_success" != 'true' || -z "$connection_key" ]]; then
    done_error=$(printf '%s' "$done_json" | json_field error || true)
    fail "Signed in, but no connection key was returned."
    info "    ${done_error:-Contact the platform team; your key can be issued from the admin panel.}"
    exit 1
  fi

  done_email=$(printf '%s' "$done_json" | json_field email || true)
  has_key=1
  ok "Signed in as ${done_email:-$email}; connection key received."
fi

# 3) Put the local launcher in Claude-3p's per-user Application Support folder.
claude_dir="$HOME/Library/Application Support/Claude-3p/MoneyMarket"
mkdir -p "$claude_dir"
cp -f "$source_tool" "$claude_dir/mcp-connect-tool.mjs"
if [[ -f "$script_dir/package.json" ]]; then
  cp -f "$script_dir/package.json" "$claude_dir/package.json"
fi

# Claude Desktop is a GUI app and may not inherit Homebrew/nvm's PATH. This
# launcher pins the npx path found in the user's Terminal and supplies Node's dir.
npx_launcher="$claude_dir/moneymarket-npx"
node_dir=$(dirname "$node_bin")
{
  printf '#!/bin/bash\n'
  printf 'export PATH=%q\n' "$node_dir:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
  printf 'exec %q "$@"\n' "$npx_bin"
} > "$npx_launcher"
chmod 700 "$npx_launcher"
ok "Installed mcp-connect-tool.mjs in $claude_dir"

# 4) Collect the optional BigQuery key before writing the MCP configuration.
bigquery_token=''
bigquery_ok=0
info ""
heading "Google BigQuery (optional)"

want_bigquery=0
if [[ $skip_bigquery -eq 1 ]]; then
  skip "Skipping BigQuery (--skip-big-query)."
elif [[ -n "$bigquery_key" ]]; then
  want_bigquery=1
else
  info "  Adds SQL access to the data warehouse from Claude."
  info "  You need your own GCP service-account JSON key. Queries run as that account."
  info "  If you do not have one, answer No; you can rerun this script later."
  info ""
  read -r -p "Add the BigQuery MCP server now? [y/N] " answer
  if [[ "$answer" =~ ^[Yy] ]]; then
    want_bigquery=1
  else
    skip "Skipped BigQuery."
  fi
fi

if [[ $want_bigquery -eq 1 ]]; then
  key_input=$(trim_ws "$bigquery_key")
  if [[ ${#key_input} -ge 2 ]]; then
    if [[ "$key_input" == \"*\" && "$key_input" == *\" ]]; then
      key_input=${key_input:1:${#key_input}-2}
    elif [[ "$key_input" == \'*\' && "$key_input" == *\' ]]; then
      key_input=${key_input:1:${#key_input}-2}
    fi
  fi

  if [[ -z "$key_input" ]]; then
    info ""
    info "  Enter the full path to your service-account JSON, for example:"
    printf '%s    /Users/you/Downloads/datawarehouse-key.json%s\n' "$GRAY" "$RESET"
    info "  A path is safer than pasting because the key does not appear on screen."
    read -r -p "  JSON path (press Enter to paste the key instead): " key_input
    key_input=$(trim_ws "$key_input")
  fi

  private_key=''
  if [[ -n "$key_input" && -f "$key_input" ]]; then
    if private_key=$("$node_bin" -e '
        const fs = require("fs");
        try {
          const value = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
          if (!value.private_key) process.exit(3);
          process.stdout.write(value.private_key);
        } catch (error) {
          console.error(error.message);
          process.exit(2);
        }
      ' "$key_input" 2>/dev/null); then
      account=$("$node_bin" -e '
        const fs = require("fs");
        const value = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
        process.stdout.write(value.client_email || "(no client_email in file)");
      ' "$key_input" 2>/dev/null || true)
      ok "Read the key for $account"
    else
      fail "Could not read '$key_input' as a service-account JSON containing private_key."
    fi
  elif [[ "$key_input" =~ BEGIN[[:space:]][A-Z[:space:]]*PRIVATE[[:space:]]KEY ]]; then
    private_key=$key_input
  elif [[ -n "$key_input" ]]; then
    fail "'$key_input' is neither an existing file nor a private key."
  else
    info ""
    printf '%s  Paste the private key or whole service-account JSON.%s\n' "$YELLOW" "$RESET"
    info "  Finish with a blank line, the PEM END line, or the closing JSON brace:"
    pasted=''
    while IFS= read -r line; do
      if [[ -z "$(trim_ws "$line")" ]]; then
        [[ -n "$pasted" ]] && break
        continue
      fi
      if [[ -n "$pasted" ]]; then pasted+=$'\n'; fi
      pasted+=$line
      [[ "$line" =~ -----END[[:space:]][A-Z[:space:]]*PRIVATE[[:space:]]KEY----- ]] && break
      [[ "$(trim_ws "$line")" == '}' && "$pasted" =~ ^[[:space:]]*\{ ]] && break
    done

    if [[ "$pasted" =~ ^[[:space:]]*\{ ]]; then
      private_key=$(printf '%s' "$pasted" | "$node_bin" -e '
        let data = "";
        process.stdin.on("data", c => data += c);
        process.stdin.on("end", () => {
          try {
            const value = JSON.parse(data);
            if (value.private_key) process.stdout.write(value.private_key);
          } catch (_) { process.exitCode = 2; }
        });
      ' 2>/dev/null || true)
      [[ -n "$private_key" ]] || fail "That looked like JSON but did not contain a readable private_key."
    else
      private_key=$pasted
    fi
  fi

  if [[ -n "$private_key" ]]; then
    private_key=$(printf '%s' "$private_key" | "$node_bin" -e '
      let data = "";
      process.stdin.on("data", c => data += c);
      process.stdin.on("end", () => process.stdout.write(data.replace(/\\n/g, "\n").trim()));
    ')
  fi

  if [[ "$private_key" =~ -----BEGIN[[:space:]][A-Z[:space:]]*PRIVATE[[:space:]]KEY----- ]]; then
    bigquery_token=$(printf '%s' "$private_key" | "$node_bin" -e '
      const chunks = [];
      process.stdin.on("data", c => chunks.push(c));
      process.stdin.on("end", () => process.stdout.write(Buffer.concat(chunks).toString("base64")));
    ')
    bigquery_ok=1
    ok "BigQuery configured: https://${mcp_host}:3011/sse"
  elif [[ -n "$private_key" ]]; then
    fail "That does not contain a PEM private-key block."
    info "    Expected text starting with -----BEGIN PRIVATE KEY-----"
    warn "BigQuery was not configured. Everything else will continue."
  else
    warn "BigQuery was not configured. Everything else will continue."
  fi
  private_key=''
fi

# 5) Merge the owned MCP entries into Claude-3p's config and preserve other keys.
cfg_dir="$HOME/Library/Application Support/Claude-3p"
cfg_path="$cfg_dir/claude_desktop_config.json"
mkdir -p "$cfg_dir"

if [[ -f "$cfg_path" ]]; then
  backup="$cfg_path.bak-$(date +%Y%m%d%H%M%S)"
  cp -p "$cfg_path" "$backup"
  ok "Backed up existing config to $backup"
fi

encoded_email=$("$node_bin" -e 'process.stdout.write(encodeURIComponent(process.argv[1]))' "$email")
config_tmp=$(mktemp "$cfg_dir/.claude-config.XXXXXX")

if ! merge_report=$(
  MM_EMAIL="$email" \
  MM_ENCODED_EMAIL="$encoded_email" \
  MM_KEY="$connection_key" \
  MM_HAS_KEY="$has_key" \
  MM_HOST="$mcp_host" \
  MM_MCP_REMOTE_VERSION="$mcp_remote_version" \
  MM_NODE="$node_bin" \
  MM_NPX_LAUNCHER="$npx_launcher" \
  MM_CONNECT_TOOL="$claude_dir/mcp-connect-tool.mjs" \
  MM_BIGQUERY_TOKEN="$bigquery_token" \
  "$node_bin" - "$cfg_path" "$config_tmp" <<'NODE'
const fs = require('fs');
const input = process.argv[2];
const output = process.argv[3];
let config = {};
let invalid = false;

if (fs.existsSync(input)) {
  try {
    config = JSON.parse(fs.readFileSync(input, 'utf8'));
    if (!config || Array.isArray(config) || typeof config !== 'object') throw new Error('not an object');
  } catch (_) {
    config = {};
    invalid = true;
  }
}

const host = process.env.MM_HOST;
const npx = process.env.MM_NPX_LAUNCHER;
const mcpRemote = `mcp-remote@${process.env.MM_MCP_REMOTE_VERSION}`;
const servers = {
  'mcp-connect': {
    command: process.env.MM_NODE,
    args: [process.env.MM_CONNECT_TOOL]
  },
  'mcp-365-auth': {
    command: npx,
    args: ['-y', mcpRemote, `https://${host}:3004/m365-auth/sse`]
  },
  'atlassian': {
    command: npx,
    args: ['-y', mcpRemote, 'https://mcp.atlassian.com/v1/mcp/authv2']
  },
  'playwright': {
    command: npx,
    args: ['-y', '@playwright/mcp@0.0.78']
  },
  'mcp-archived': {
    command: npx,
    args: ['-y', mcpRemote, `https://${host}:3012/sse`]
  }
};

if (process.env.MM_HAS_KEY === '1') {
  servers['mcp-365'] = {
    command: npx,
    args: [
      '-y', mcpRemote,
      `https://${host}:3002/sse?userId=${process.env.MM_ENCODED_EMAIL}`,
      '--header', `x-mcp-key:${process.env.MM_KEY}`
    ]
  };
}

let keptBigQuery = false;
if (process.env.MM_BIGQUERY_TOKEN) {
  servers['mcp-bigquery'] = {
    command: npx,
    args: [
      '-y', mcpRemote, `https://${host}:3011/sse`,
      '--header', `x-mcp-key:${process.env.MM_BIGQUERY_TOKEN}`
    ]
  };
} else if (config.mcpServers && config.mcpServers['mcp-bigquery']) {
  servers['mcp-bigquery'] = config.mcpServers['mcp-bigquery'];
  keptBigQuery = true;
}

config.mcpServers = servers;
if (!Object.prototype.hasOwnProperty.call(config, 'deploymentMode')) config.deploymentMode = '3p';
fs.writeFileSync(output, JSON.stringify(config, null, 2) + '\n', {mode: 0o600});
process.stdout.write(JSON.stringify({invalid, keptBigQuery}));
NODE
); then
  rm -f "$config_tmp"
  fail "Could not build the Claude Desktop configuration."
  exit 1
fi

mv -f "$config_tmp" "$cfg_path"
chmod 600 "$cfg_path"
if [[ "$(printf '%s' "$merge_report" | json_field invalid || true)" == 'true' ]]; then
  warn "The old config was not valid JSON, so a fresh config was written; the backup was kept."
fi
if [[ "$(printf '%s' "$merge_report" | json_field keptBigQuery || true)" == 'true' ]]; then
  ok "Kept the existing mcp-bigquery entry."
  bigquery_ok=1
fi
ok "Wrote config to $cfg_path"

# 5b) Bedrock credentials. The MDM preference decides which named AWS profile
# Claude Desktop uses; bedrock-ai is the fallback used by the Windows script.
aws_profile='bedrock-ai'
preference_candidates=(
  "/Library/Managed Preferences/$USER/com.anthropic.claudefordesktop"
  "/Library/Managed Preferences/com.anthropic.claudefordesktop"
  "$HOME/Library/Managed Preferences/com.anthropic.claudefordesktop"
  "com.anthropic.claudefordesktop"
)
for preference in "${preference_candidates[@]}"; do
  candidate=$(defaults read "$preference" inferenceBedrockProfile 2>/dev/null || true)
  candidate=$(trim_ws "$candidate")
  if [[ -n "$candidate" ]]; then
    aws_profile=$candidate
    break
  fi
done

# Bootstrap configurations may carry the same value inside enterpriseConfig.
if [[ "$aws_profile" == 'bedrock-ai' && -f "$cfg_path" ]]; then
  candidate=$("$node_bin" -e '
    const fs = require("fs");
    try {
      const c = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
      process.stdout.write((c.enterpriseConfig && c.enterpriseConfig.inferenceBedrockProfile) || "");
    } catch (_) {}
  ' "$cfg_path")
  [[ -n "$candidate" ]] && aws_profile=$candidate
fi

cred_dir="$HOME/.aws"
cred_path="$cred_dir/credentials"
has_existing=0
if [[ -f "$cred_path" ]]; then
  if MM_AWS_PROFILE="$aws_profile" "$node_bin" -e '
      const fs = require("fs");
      const target = process.env.MM_AWS_PROFILE;
      const found = fs.readFileSync(process.argv[1], "utf8").split(/\r?\n/).some(line => {
        const m = line.match(/^\s*\[\s*(.*?)\s*\]\s*$/);
        return m && m[1] === target;
      });
      process.exit(found ? 0 : 1);
    ' "$cred_path"; then
    has_existing=1
  fi
fi

if [[ $skip_aws -eq 1 ]]; then
  skip "Skipping Bedrock credentials (--skip-aws-credentials)."
else
  if [[ -z "$aws_access_key_id" ]]; then
    info ""
    heading "Bedrock credentials (AWS)"
    info "  Profile: [$aws_profile] in $cred_path"
    if [[ $has_existing -eq 1 ]]; then
      printf '%s  A profile named [%s] already exists.%s\n' "$YELLOW" "$aws_profile" "$RESET"
      info "  Entering a new key replaces only that profile. Press Enter to keep it unchanged."
    else
      info "  No [$aws_profile] profile exists; Claude cannot reach Bedrock without credentials."
    fi
    read -r -p "  AWS Access Key ID (press Enter to skip): " aws_access_key_id
  fi

  aws_access_key_id=$(trim_ws "$aws_access_key_id")
  if [[ -z "$aws_access_key_id" ]]; then
    skip "Bedrock credentials unchanged."
  else
    if [[ ! "$aws_access_key_id" =~ ^(AKIA|ASIA)[0-9A-Z]{16}$ ]]; then
      fail "'$aws_access_key_id' is not a valid AWS Access Key ID."
      info "    Expected AKIA or ASIA followed by 16 uppercase letters or digits."
      exit 1
    fi

    if [[ -z "$aws_secret_access_key" ]]; then
      read -r -s -p "  AWS Secret Access Key: " aws_secret_access_key
      info ""
    fi
    aws_secret_access_key=$(trim_ws "$aws_secret_access_key")
    if [[ ${#aws_secret_access_key} -lt 40 ]]; then
      fail "That secret looks too short (AWS secrets are at least 40 characters)."
      exit 1
    fi

    if [[ "$aws_access_key_id" == ASIA* && -z "$aws_session_token" ]]; then
      read -r -s -p "  AWS Session Token (required for ASIA temporary keys): " aws_session_token
      info ""
    fi
    aws_session_token=$(trim_ws "$aws_session_token")
    if [[ "$aws_access_key_id" == ASIA* && -z "$aws_session_token" ]]; then
      fail "An ASIA temporary access key also requires its AWS session token."
      exit 1
    fi

    mkdir -p "$cred_dir"
    chmod 700 "$cred_dir"
    if [[ -f "$cred_path" ]]; then
      cp -p "$cred_path" "$cred_path.bak-$(date +%Y%m%d%H%M%S)"
    fi
    cred_tmp=$(mktemp "$cred_dir/.credentials.XXXXXX")

    MM_AWS_PROFILE="$aws_profile" \
    MM_AWS_ACCESS_KEY_ID="$aws_access_key_id" \
    MM_AWS_SECRET_ACCESS_KEY="$aws_secret_access_key" \
    MM_AWS_SESSION_TOKEN="$aws_session_token" \
    "$node_bin" - "$cred_path" "$cred_tmp" <<'NODE'
const fs = require('fs');
const input = process.argv[2];
const output = process.argv[3];
const target = process.env.MM_AWS_PROFILE;
const source = fs.existsSync(input) ? fs.readFileSync(input, 'utf8').split(/\r?\n/) : [];
const kept = [];
let inTarget = false;

for (const line of source) {
  const match = line.match(/^\s*\[\s*(.*?)\s*\]\s*$/);
  if (match) {
    inTarget = match[1] === target;
    if (inTarget) continue;
  }
  if (!inTarget) kept.push(line);
}
while (kept.length && /^\s*$/.test(kept[kept.length - 1])) kept.pop();
if (kept.length) kept.push('');
kept.push(`[${target}]`);
kept.push(`aws_access_key_id = ${process.env.MM_AWS_ACCESS_KEY_ID}`);
kept.push(`aws_secret_access_key = ${process.env.MM_AWS_SECRET_ACCESS_KEY}`);
if (process.env.MM_AWS_SESSION_TOKEN) kept.push(`aws_session_token = ${process.env.MM_AWS_SESSION_TOKEN}`);
fs.writeFileSync(output, kept.join('\n') + '\n', {mode: 0o600});
NODE
    mv -f "$cred_tmp" "$cred_path"
    chmod 600 "$cred_path"
    if [[ $has_existing -eq 1 ]]; then
      ok "Replaced profile [$aws_profile] in $cred_path; all other profiles were preserved."
    else
      ok "Added profile [$aws_profile] in $cred_path; all other profiles were preserved."
    fi
    aws_secret_access_key=''
    aws_session_token=''
  fi
fi

# 6) Jira / Confluence OAuth.
atlassian_url='https://mcp.atlassian.com/v1/mcp/authv2'
auth_root="$HOME/.mcp-auth"
atlassian_ok=0

info ""
heading "Jira / Confluence (Atlassian)"
info "  This uses Atlassian OAuth; there is no API token to create."
info "  You sign in as yourself and keep your existing Jira/Confluence permissions."
info ""

existing_token=''
if [[ -d "$auth_root" ]]; then
  existing_token=$(find "$auth_root" -type f -name '*_tokens.json' -print -quit 2>/dev/null || true)
fi

oauth_pid=''
terminate_tree() {
  local parent=$1 child
  while IFS= read -r child; do
    [[ -n "$child" ]] && terminate_tree "$child"
  done < <(pgrep -P "$parent" 2>/dev/null || true)
  kill "$parent" 2>/dev/null || true
}
cleanup_oauth() {
  if [[ -n "$oauth_pid" ]] && kill -0 "$oauth_pid" 2>/dev/null; then
    terminate_tree "$oauth_pid"
    wait "$oauth_pid" 2>/dev/null || true
  fi
}
trap cleanup_oauth EXIT
trap 'cleanup_oauth; exit 130' INT TERM

if [[ -n "$existing_token" ]]; then
  ok "An Atlassian sign-in already exists on this Mac; skipping."
  atlassian_ok=1
elif [[ $skip_atlassian -eq 1 ]]; then
  warn "Atlassian sign-in skipped. A browser opens the first time you use Jira in Claude."
else
  read -r -p "Sign in to Atlassian now? [Y/n] " answer
  if [[ "$answer" =~ ^[Nn] ]]; then
    warn "Skipped. A browser opens the first time you use Jira in Claude."
  else
    out_log="${TMPDIR:-/tmp}/mm-atlassian-auth.out.log"
    err_log="${TMPDIR:-/tmp}/mm-atlassian-auth.err.log"
    : > "$out_log"
    : > "$err_log"

    leftover_pids=$(pgrep -f 'mcp-remote.*mcp\.atlassian\.com|mcp\.atlassian\.com.*mcp-remote' 2>/dev/null || true)
    if [[ -n "$leftover_pids" ]]; then
      warn "Found an old Atlassian mcp-remote process holding the OAuth callback. Closing it."
      while IFS= read -r old_pid; do
        [[ "$old_pid" =~ ^[0-9]+$ && "$old_pid" != "$$" ]] && terminate_tree "$old_pid"
      done <<< "$leftover_pids"
      sleep 1
    fi
    if [[ -d "$auth_root" ]]; then
      find "$auth_root" -type f -name '*_lock.json' -delete 2>/dev/null || true
    fi

    callback_port=$("$node_bin" -e '
      const server = require("net").createServer();
      server.listen(0, "127.0.0.1", () => {
        process.stdout.write(String(server.address().port));
        server.close();
      });
    ')
    marker=$(mktemp "${TMPDIR:-/tmp}/mm-atlassian-marker.XXXXXX")
    info "Opening Atlassian sign-in (callback port $callback_port)..."
    "$npx_launcher" -y "mcp-remote@$mcp_remote_version" "$atlassian_url" "$callback_port" >"$out_log" 2>"$err_log" &
    oauth_pid=$!

    url_shown=0
    crashed=0
    for ((attempt=0; attempt<90; attempt++)); do
      new_token=''
      if [[ -d "$auth_root" ]]; then
        new_token=$(find "$auth_root" -type f -name '*_tokens.json' -newer "$marker" -print -quit 2>/dev/null || true)
      fi
      if [[ -n "$new_token" ]]; then
        atlassian_ok=1
        break
      fi

      if [[ $url_shown -eq 0 ]]; then
        auth_url=$(grep -Eho 'https://[^[:space:]]*(authorize|oauth)[^[:space:]]*' "$err_log" "$out_log" 2>/dev/null | head -n 1 || true)
        if [[ -n "$auth_url" ]]; then
          printf '%s  If no browser opened, paste this URL yourself:%s\n' "$YELLOW" "$RESET"
          info "  $auth_url"
          url_shown=1
        fi
      fi

      if ! kill -0 "$oauth_pid" 2>/dev/null; then
        sleep 1
        if [[ -d "$auth_root" ]]; then
          new_token=$(find "$auth_root" -type f -name '*_tokens.json' -newer "$marker" -print -quit 2>/dev/null || true)
        fi
        [[ -n "${new_token:-}" ]] && atlassian_ok=1 || crashed=1
        break
      fi
      sleep 2
    done

    cleanup_oauth
    oauth_pid=''
    rm -f "$marker"

    if [[ $atlassian_ok -eq 1 ]]; then
      ok "Atlassian sign-in complete; Jira and Confluence are ready."
    else
      if [[ $crashed -eq 1 ]]; then
        warn "The Atlassian helper stopped before sign-in finished. Last output:"
        tail -n 15 "$err_log" 2>/dev/null | sed 's/^/    /'
        if grep -q 'EADDRINUSE' "$err_log" 2>/dev/null; then
          warn "The callback port is occupied. Fully quit Claude Desktop, then rerun this script."
        fi
      else
        warn "No completed Atlassian sign-in was detected within three minutes."
      fi
      info "    This is not a blocker: a browser opens the first time you use Jira in Claude."
      info "    Full log: $err_log"
    fi
  fi
fi

connection_key=''
bigquery_token=''

info ""
if [[ $has_key -eq 1 ]]; then
  printf '%sDone - mcp-365 is configured. Next steps:%s\n' "$GREEN" "$RESET"
  info "  1) Be on the company network or VPN ($mcp_host is internal-only)."
  info "  2) Fully quit Claude Desktop with Command-Q, then reopen it."
  info "  3) Try: Read my 5 most recent inbox emails."
  if [[ $atlassian_ok -eq 1 ]]; then
    info "  4) Jira/Confluence is signed in. Try: List my assigned Jira issues."
  else
    info "  4) Jira/Confluence opens a browser the first time you use it."
  fi
  if [[ $bigquery_ok -eq 1 ]]; then
    info "  5) BigQuery: try asking Claude to list tables in your dataset."
  else
    info "  5) BigQuery was not installed. To add it later, rerun with:"
    info "     --key YOUR_KEY --skip-aws-credentials --skip-atlassian-login"
  fi
  info "  6) Archived documents: try asking Claude to check the archive for a contract."
else
  warn "mcp-365 was not installed because no connection key was obtained."
fi
