# MoneyMarket Claude Desktop MCP setup — macOS

This package configures the MoneyMarket **Claude Desktop 3P** build on macOS.
It is for the company-approved AWS Bedrock deployment, not a normal first-party
Claude Teams configuration.

## Before you run it

1. Confirm Claude Desktop 3P is already installed.
2. Connect to the company network or VPN.
3. Install the current Node.js LTS release and verify:

   ```bash
   node --version
   npx --version
   ```

4. Fully quit Claude Desktop with `Command-Q`.
5. Keep `setup-macos.sh`, `mcp-connect-tool.mjs`, and `package.json` together.
6. Run the script as your normal user. **Do not use `sudo`.**

## Install

In Terminal, enter the folder containing this package and run:

```bash
chmod +x setup-macos.sh
./setup-macos.sh
```

Entering secrets through the prompts is safer than passing them as command-line
arguments, which can remain in shell history.

The script will:

- authenticate your personal Microsoft 365 connection;
- install the local MCP connector under
  `~/Library/Application Support/Claude-3p/MoneyMarket/`;
- write `~/Library/Application Support/Claude-3p/claude_desktop_config.json`;
- optionally configure BigQuery and Bedrock credentials;
- optionally complete Atlassian OAuth in your browser; and
- make timestamped backups before replacing an existing Claude configuration or
  AWS profile.

When it finishes, quit Claude Desktop again with `Command-Q`, reopen it, and try:

- `Read my 5 most recent inbox emails.`
- `List my assigned Jira issues.`
- `Check if contract 10128097 is in the archive.`

## Important security notes

- The M365 connection key is stored in Claude's local configuration.
- AWS credentials are stored in `~/.aws/credentials` with owner-only permissions.
- If BigQuery is enabled, the service-account private key is Base64-encoded in
  Claude's configuration. Base64 is not encryption.
- The optional `mcp-connect` tool downloads additional MCP packages from the
  company S3 bucket and registers their commands locally. Install only exact MCP
  names approved by the platform team.
- The remote MCP bridge is pinned to `mcp-remote@0.8.2` so a future npm release
  cannot silently change the installed setup.
- Every `mcp-connect` configuration change now creates a backup and updates only
  the Claude-3p configuration, never the first-party Claude Teams config.
- A downloaded MCP package that still requires PowerShell, `.cmd`, `.bat`, or an
  unconvertible Windows path is rejected with a clear error instead of installing
  a broken entry.

## MCPs versus Claude skills

This ZIP contains MCP setup files. It does **not** contain Claude skill folders or
`SKILL.md` files. If the team has a separate skills ZIP or a list of skills to run
after setup, that must be checked separately.

## Useful options

```bash
./setup-macos.sh --skip-big-query
./setup-macos.sh --skip-atlassian-login
./setup-macos.sh --skip-aws-credentials
./setup-macos.sh --help
```

## Troubleshooting

- **Internal MCPs show “Server disconnected”:** connect to the VPN, verify Node
  is installed, and completely restart Claude Desktop.
- **Atlassian callback says `EADDRINUSE`:** quit Claude Desktop and rerun the
  setup. The script clears only stale Atlassian callback state.
- **Playwright needs a browser:** run `npx playwright install chrome` in Terminal.
- **Claude cannot reach a model:** verify that the Mac received the company's
  managed Bedrock configuration and that the named AWS profile exists.
- **Need to restore:** use the timestamped `.bak-...` file beside the affected
  Claude config or AWS credentials file.
