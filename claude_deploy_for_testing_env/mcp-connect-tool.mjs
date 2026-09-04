import { execFileSync } from "child_process";
import fs from "fs";
import path from "path";
import os from "os";
import readline from "readline";
import { fileURLToPath } from "url";

const BUCKET_NAME = process.env.S3_BUCKET_NAME || "mcp-servers-s3";
const AWS_REGION = process.env.AWS_REGION || "eu-west-1";
const TOOL_DIR = path.dirname(fileURLToPath(import.meta.url));

function validateRemoteSettings() {
  if (!/^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$/.test(BUCKET_NAME)) {
    throw new Error("Invalid S3 bucket name.");
  }
  if (!/^[a-z]{2}(?:-gov)?-[a-z]+-\d$/.test(AWS_REGION)) {
    throw new Error("Invalid AWS region.");
  }
}

function validateInstallInput(serverName, userEmail) {
  if (typeof serverName !== "string" || !/^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$/.test(serverName)) {
    throw new Error("Invalid server name. Use only letters, numbers, dot, underscore, and hyphen (maximum 64 characters).");
  }
  if (typeof userEmail !== "string" || !/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(userEmail)) {
    throw new Error("Invalid user email address.");
  }
}

/**
 * Returns known Claude Desktop config paths, with the 3P path first.
 */
function getClaudeConfigPaths() {
  const paths = [];
  if (process.platform === "win32") {
    const localAppData = process.env.LOCALAPPDATA || path.join(os.homedir(), "AppData", "Local");
    const appData = process.env.APPDATA || path.join(os.homedir(), "AppData", "Roaming");

    // Primary target specified in prompt: AppData\Local\Claude-3p\claude_desktop_config.json
    paths.push(path.join(localAppData, "Claude-3p", "claude_desktop_config.json"));
    // Additional target paths for standard Claude Desktop installations
    paths.push(path.join(localAppData, "Claude", "claude_desktop_config.json"));
    paths.push(path.join(appData, "Claude", "claude_desktop_config.json"));
  } else if (process.platform === "darwin") {
    paths.push(path.join(os.homedir(), "Library", "Application Support", "Claude-3p", "claude_desktop_config.json"));
    paths.push(path.join(os.homedir(), "Library", "Application Support", "Claude", "claude_desktop_config.json"));
  } else {
    paths.push(path.join(os.homedir(), ".config", "Claude-3p", "claude_desktop_config.json"));
    paths.push(path.join(os.homedir(), ".config", "Claude", "claude_desktop_config.json"));
  }
  return paths;
}

function getClaudeConfigPath() {
  // This tool belongs to the MoneyMarket 3P deployment. Never fall back to an
  // existing first-party Claude config, because that would modify Claude Teams.
  return getClaudeConfigPaths()[0];
}

/**
 * Dynamic target folder for downloaded MCP packages.
 */
function getTargetFolderPath(serverName) {
  if (process.platform === "win32") {
    return path.join("C:", "Claude", serverName);
  } else if (process.platform === "darwin") {
    return path.join(TOOL_DIR, "servers", serverName);
  } else {
    return path.join(os.homedir(), ".local", "share", "Claude-3p", "MoneyMarket", "servers", serverName);
  }
}

/**
 * Strips UTF-8 BOM, comments, and trailing commas from JSON string safely
 */
function cleanJsonString(str) {
  if (typeof str !== "string") return str;
  let content = str;
  if (content.charCodeAt(0) === 0xFEFF) {
    content = content.slice(1);
  }
  // Strip single-line and multi-line comments
  content = content.replace(/\/\*[\s\S]*?\*\/|([^\\:]|^)\/\/.*/g, "$1");
  // Strip trailing commas before closing braces/brackets
  content = content.replace(/,\s*([\}\]])/g, "$1");
  return content;
}

/**
 * Parses JSON content or unbraced JSON snippets safely (e.g., "mcp-365": { ... })
 */
function parseConfigJsonSnippet(rawContent) {
  let cleaned = cleanJsonString(rawContent).trim();
  try {
    return JSON.parse(cleaned);
  } catch (err1) {
    // If snippet is missing root { }, wrap it in { }
    try {
      let wrapped = cleaned;
      if (!wrapped.startsWith("{")) {
        wrapped = "{\n" + wrapped + "\n}";
      }
      wrapped = cleanJsonString(wrapped);
      return JSON.parse(wrapped);
    } catch (err2) {
      try {
        let wrapped = cleaned.replace(/,$/, "");
        if (!wrapped.startsWith("{")) {
          wrapped = "{\n" + wrapped + "\n}";
        }
        wrapped = cleanJsonString(wrapped);
        return JSON.parse(wrapped);
      } catch (err3) {
        throw new Error(`Failed to parse config.json snippet: ${err1.message}`);
      }
    }
  }
}

/**
 * Safely reads claude_desktop_config.json preserving structure
 */
function readClaudeConfig(configPath) {
  if (!fs.existsSync(configPath)) {
    return { mcpServers: {} };
  }
  const content = fs.readFileSync(configPath, "utf-8");
  const parsed = parseConfigJsonSnippet(content);
  if (!parsed || Array.isArray(parsed) || typeof parsed !== "object") {
    throw new Error(`Claude config is not a JSON object: ${configPath}`);
  }
  if (!parsed.mcpServers || Array.isArray(parsed.mcpServers) || typeof parsed.mcpServers !== "object") {
    parsed.mcpServers = {};
  }
  return parsed;
}

/**
 * Backs up and writes claude_desktop_config.json with owner-only permissions.
 */
function writeClaudeConfig(configPath, configData) {
  const dir = path.dirname(configPath);
  if (!fs.existsSync(dir)) {
    fs.mkdirSync(dir, { recursive: true });
  }
  let backupPath = null;
  if (fs.existsSync(configPath)) {
    const stamp = new Date().toISOString().replace(/[-:TZ.]/g, "");
    backupPath = `${configPath}.bak-${stamp}`;
    fs.copyFileSync(configPath, backupPath, fs.constants.COPYFILE_EXCL);
  }
  const content = JSON.stringify(configData, null, 2) + "\n";
  fs.writeFileSync(configPath, content, { encoding: "utf-8", mode: 0o600 });
  try { fs.chmodSync(configPath, 0o600); } catch (_) { /* Windows ACLs are handled separately. */ }
  return backupPath;
}

/**
 * Replaces ${userId}, ${USER_ID}, ${email} in strings/objects
 */
function replaceUserIdInText(text, userId) {
  if (typeof text !== "string") return text;
  return text
    .replace(/\$\{userId\}/g, userId)
    .replace(/\$\{USER_ID\}/g, userId)
    .replace(/\$\{email\}/g, userId);
}

function interpolateUserId(obj, userId) {
  if (typeof obj === "string") return replaceUserIdInText(obj, userId);
  if (Array.isArray(obj)) return obj.map(value => interpolateUserId(value, userId));
  if (obj && typeof obj === "object") {
    return Object.fromEntries(Object.entries(obj).map(([key, value]) => [key, interpolateUserId(value, userId)]));
  }
  return obj;
}

function countFiles(dir) {
  if (!fs.existsSync(dir)) return 0;
  let count = 0;
  for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
    const fullPath = path.join(dir, entry.name);
    if (entry.isDirectory()) count += countFiles(fullPath);
    else if (entry.isFile()) count++;
  }
  return count;
}

function decodeXmlText(value) {
  return value
    .replace(/&lt;/g, "<")
    .replace(/&gt;/g, ">")
    .replace(/&quot;/g, '"')
    .replace(/&apos;/g, "'")
    .replace(/&amp;/g, "&");
}

function safeDestinationPath(targetDir, relativePath) {
  const base = path.resolve(targetDir);
  const destination = path.resolve(base, relativePath);
  if (destination !== base && !destination.startsWith(base + path.sep)) {
    throw new Error(`Unsafe path in MCP package: ${relativePath}`);
  }
  return destination;
}

/**
 * Recursively scans directory and replaces ${userId} in text files
 */
function replacePlaceholdersInDirectory(dir, userEmail) {
  if (!fs.existsSync(dir)) return;
  const entries = fs.readdirSync(dir, { withFileTypes: true });
  for (const entry of entries) {
    const fullPath = path.join(dir, entry.name);
    if (entry.isDirectory()) {
      replacePlaceholdersInDirectory(fullPath, userEmail);
    } else if (entry.isFile()) {
      const ext = path.extname(entry.name).toLowerCase();
      const isTextFile = [
        ".json", ".cmd", ".bat", ".ps1", ".txt", ".js", ".mjs", ".cjs", ".ts",
        ".env", ".sh", ".yml", ".yaml", ".md", ".html", ".css", ".config"
      ].includes(ext) || entry.name.startsWith(".env");

      if (isTextFile) {
        try {
          let content = fs.readFileSync(fullPath, "utf-8");
          if (content.charCodeAt(0) === 0xFEFF) {
            content = content.slice(1);
          }
          const updated = replaceUserIdInText(content, userEmail);
          if (updated !== content) {
            fs.writeFileSync(fullPath, updated, "utf-8");
          }
        } catch (e) {
          // Skip binary or unreadable files
        }
      }
    }
  }
}

/**
 * Downloads files from S3 bucket for any given serverName
 */
async function downloadServerFilesFromS3(serverName, targetDir) {
  validateRemoteSettings();
  let downloadedCount = 0;

  // 1. Try AWS CLI sync without signing requests (IP-whitelisted S3 bucket)
  try {
    const s3Uri = `s3://${BUCKET_NAME}/${serverName}/`;
    // Argument-array execution prevents a model-supplied server name from
    // becoming shell syntax.
    execFileSync("aws", [
      "s3", "sync", s3Uri, targetDir,
      "--no-sign-request", "--region", AWS_REGION
    ], { stdio: "ignore" });
    downloadedCount = countFiles(targetDir);
  } catch (e) {
    // AWS CLI not installed or sync failed, fallback to HTTPS
  }

  // 2. Fallback: Fetch directly over HTTPS from IP-whitelisted S3 bucket
  if (downloadedCount === 0) {
    try {
      const listUrl = `https://${BUCKET_NAME}.s3.${AWS_REGION}.amazonaws.com/?prefix=${encodeURIComponent(serverName)}/`;
      const resp = await fetch(listUrl);
      if (resp.ok) {
        const xml = await resp.text();
        const matches = [...xml.matchAll(/<Key>(.*?)<\/Key>/g)];
        const keys = matches.map(m => decodeXmlText(m[1]));

        for (const key of keys) {
          if (key.endsWith("/")) continue;
          const relativePath = key.substring(serverName.length + 1);
          if (!relativePath) continue;

          const fileUrl = `https://${BUCKET_NAME}.s3.${AWS_REGION}.amazonaws.com/${encodeURIComponent(serverName)}/${relativePath.split("/").map(encodeURIComponent).join("/")}`;
          const fileResp = await fetch(fileUrl);
          if (fileResp.ok) {
            const content = Buffer.from(await fileResp.arrayBuffer());
            const destPath = safeDestinationPath(targetDir, relativePath);
            fs.mkdirSync(path.dirname(destPath), { recursive: true });
            if (fs.existsSync(destPath) && fs.lstatSync(destPath).isSymbolicLink()) {
              throw new Error(`Refusing to overwrite symlink: ${destPath}`);
            }
            fs.writeFileSync(destPath, content);
            downloadedCount++;
          }
        }
      }
    } catch (e) {
      console.error("HTTPS S3 list error:", e.message);
    }
  }

  // 3. Direct fetch of config.json if still missing
  const configJsonPath = path.join(targetDir, "config.json");
  if (!fs.existsSync(configJsonPath)) {
    try {
      const directConfigUrl = `https://${BUCKET_NAME}.s3.${AWS_REGION}.amazonaws.com/${encodeURIComponent(serverName)}/config.json`;
      const configResp = await fetch(directConfigUrl);
      if (configResp.ok) {
        const content = Buffer.from(await configResp.arrayBuffer());
        fs.mkdirSync(targetDir, { recursive: true });
        if (fs.existsSync(configJsonPath) && fs.lstatSync(configJsonPath).isSymbolicLink()) {
          throw new Error(`Refusing to overwrite symlink: ${configJsonPath}`);
        }
        fs.writeFileSync(configJsonPath, content);
        downloadedCount++;
      }
    } catch (e) {
      console.error("Direct config.json fetch error:", e.message);
    }
  }

  return downloadedCount;
}

/**
 * Extracts MCP server definitions from parsed config.json
 */
function extractMcpServers(parsedConfig, defaultServerName) {
  const result = {};

  if (parsedConfig.command || parsedConfig.url) {
    result[defaultServerName] = parsedConfig;
    return result;
  }

  if (parsedConfig[defaultServerName] && typeof parsedConfig[defaultServerName] === "object") {
    result[defaultServerName] = parsedConfig[defaultServerName];
    return result;
  }

  const keys = Object.keys(parsedConfig);
  let foundAny = false;
  for (const k of keys) {
    const val = parsedConfig[k];
    if (val && typeof val === "object" && (val.command || val.url || val.args)) {
      result[k] = val;
      foundAny = true;
    }
  }

  if (!foundAny) {
    result[defaultServerName] = parsedConfig;
  }

  return result;
}

function adaptDownloadedPath(value, serverName, targetDir) {
  if (process.platform !== "darwin" || typeof value !== "string") return value;
  const roots = [`C:\\Claude\\${serverName}`, `C:/Claude/${serverName}`];
  for (const root of roots) {
    if (value.toLowerCase().startsWith(root.toLowerCase())) {
      const suffix = value.slice(root.length).replace(/^[\\/]+/, "").split(/[\\/]+/).filter(Boolean);
      return path.join(targetDir, ...suffix);
    }
  }
  return value;
}

function adaptValueForPlatform(value, serverName, targetDir) {
  if (typeof value === "string") return adaptDownloadedPath(value, serverName, targetDir);
  if (Array.isArray(value)) return value.map(item => adaptValueForPlatform(item, serverName, targetDir));
  if (value && typeof value === "object") {
    return Object.fromEntries(Object.entries(value).map(([key, item]) => [
      key,
      adaptValueForPlatform(item, serverName, targetDir)
    ]));
  }
  return value;
}

function containsUnsupportedWindowsValue(value) {
  if (typeof value === "string") {
    return /^[A-Za-z]:\\/.test(value) ||
      /%(LOCALAPPDATA|APPDATA|USERPROFILE)%/i.test(value) ||
      /\.(cmd|bat|ps1)(?:$|\s)/i.test(value);
  }
  if (Array.isArray(value)) return value.some(containsUnsupportedWindowsValue);
  if (value && typeof value === "object") return Object.values(value).some(containsUnsupportedWindowsValue);
  return false;
}

function adaptMcpServersForPlatform(servers, serverName, targetDir) {
  const adapted = {};
  for (const [name, original] of Object.entries(servers)) {
    const definition = adaptValueForPlatform(original, serverName, targetDir);
    if (process.platform === "darwin") {
      if (typeof definition.command === "string" && /^node(?:\.exe)?$/i.test(definition.command)) {
        definition.command = process.execPath;
      } else if (typeof definition.command === "string" && /^npx(?:\.cmd)?$/i.test(definition.command)) {
        const launcher = path.join(TOOL_DIR, "moneymarket-npx");
        if (!fs.existsSync(launcher)) {
          throw new Error(`The macOS npx launcher is missing: ${launcher}. Rerun setup-macos.sh.`);
        }
        definition.command = launcher;
      }

      if (typeof definition.command === "string" && (
        /\.(cmd|bat|ps1)$/i.test(definition.command) ||
        /^(powershell|powershell\.exe|pwsh|cmd|cmd\.exe)$/i.test(definition.command)
      )) {
        throw new Error(`MCP '${name}' is Windows-only (${definition.command}). Ask the platform team for a macOS package.`);
      }
      if (containsUnsupportedWindowsValue(definition)) {
        throw new Error(`MCP '${name}' still contains an unsupported Windows path. Ask the platform team for a macOS package.`);
      }
    }
    adapted[name] = definition;
  }
  return adapted;
}

/**
 * Main install handler
 */
async function handleInstall(serverName, userEmail) {
  validateInstallInput(serverName, userEmail);
  const targetDir = getTargetFolderPath(serverName);

  if (!fs.existsSync(targetDir)) {
    fs.mkdirSync(targetDir, { recursive: true });
  }

  // Step 1: Download files from S3 for the requested serverName
  const downloadedCount = await downloadServerFilesFromS3(serverName, targetDir);

  if (downloadedCount === 0 || !fs.existsSync(path.join(targetDir, "config.json"))) {
    throw new Error(`Δεν βρέθηκε το MCP server '${serverName}' στο S3 bucket (https://${BUCKET_NAME}.s3.${AWS_REGION}.amazonaws.com/${serverName}/)`);
  }

  // Step 2: Replace ${userId} in all downloaded text files
  replacePlaceholdersInDirectory(targetDir, userEmail);

  // Step 3: Read & parse config.json (supporting unbraced JSON snippets)
  const configJsonPath = path.join(targetDir, "config.json");
  if (!fs.existsSync(configJsonPath)) {
    throw new Error(`Could not find or download config.json for '${serverName}' from https://${BUCKET_NAME}.s3.${AWS_REGION}.amazonaws.com/${serverName}/config.json`);
  }

  let rawContent = fs.readFileSync(configJsonPath, "utf-8");
  let parsedConfig = parseConfigJsonSnippet(rawContent);
  parsedConfig = interpolateUserId(parsedConfig, userEmail);

  const serversToAdd = adaptMcpServersForPlatform(
    extractMcpServers(parsedConfig, serverName),
    serverName,
    targetDir
  );

  // Step 4: Update claude_desktop_config.json safely
  const configPath = getClaudeConfigPath();
  const fullConfig = readClaudeConfig(configPath);
  for (const [sKey, sVal] of Object.entries(serversToAdd)) {
    fullConfig.mcpServers[sKey] = sVal;
  }
  const backupPath = writeClaudeConfig(configPath, fullConfig);

  return {
    content: [
      {
        type: "text",
        text: `✅ Επιτυχής αυτόματη εγκατάσταση του '${serverName}' για το ${userEmail}!\n📂 Φάκελος: ${targetDir} (${downloadedCount} αρχεία)\n⚙️ Config update: ${configPath}${backupPath ? `\n🛟 Backup: ${backupPath}` : ""}\n🚀 Κάνε επανεκκίνηση το Claude Desktop για να ενεργοποιηθεί το ${serverName}.`
      }
    ]
  };
}

// Native JSON-RPC 2.0 stdio listener
const rl = readline.createInterface({
  input: process.stdin,
  output: process.stdout,
  terminal: false
});

const installLocation = process.platform === "darwin"
  ? `${TOOL_DIR}/servers/<serverName>`
  : process.platform === "win32"
    ? "C:\\Claude\\<serverName>"
    : `${os.homedir()}/.local/share/Claude-3p/MoneyMarket/servers/<serverName>`;

const installToolDescription =
  `Install an IT-approved MCP package from the MoneyMarket S3 bucket into ${installLocation}, ` +
  "replace its userId placeholders, back up the Claude-3p config, and register the server. " +
  "This downloads code and changes local configuration; call it only after the user explicitly names the approved MCP server to install.";

function sendResponse(obj) {
  process.stdout.write(JSON.stringify(obj) + "\n");
}

rl.on("line", async (line) => {
  if (!line.trim()) return;
  try {
    const req = JSON.parse(line.trim());
    const { id, method, params } = req;

    if (method === "initialize") {
      sendResponse({
        jsonrpc: "2.0",
        id,
        result: {
          protocolVersion: "2024-11-05",
          capabilities: { tools: {} },
          serverInfo: { name: "mcp-connect-local", version: "1.0.0" }
        }
      });
    } else if (method === "notifications/initialized") {
      // Notification, no response needed
    } else if (method === "tools/list") {
      sendResponse({
        jsonrpc: "2.0",
        id,
        result: {
          tools: [
            {
              name: "install_mcp_server",
              description: installToolDescription,
              inputSchema: {
                type: "object",
                properties: {
                  serverName: { type: "string", description: "Name of any MCP server (e.g. mcp-test, mcp-365, mcp-jira, etc.)" },
                  userEmail: { type: "string", description: "User email address e.g. autopilot@insurancemarket.gr" }
                },
                required: ["serverName", "userEmail"]
              }
            },
            {
              name: "connect_mcp_server",
              description: `Alias for install_mcp_server. ${installToolDescription}`,
              inputSchema: {
                type: "object",
                properties: {
                  serverName: { type: "string", description: "Name of any MCP server (e.g. mcp-test, mcp-365, mcp-jira, etc.)" },
                  userEmail: { type: "string", description: "User email address e.g. autopilot@insurancemarket.gr" }
                },
                required: ["serverName", "userEmail"]
              }
            }
          ]
        }
      });
    } else if (method === "tools/call") {
      const toolName = params?.name;
      const args = params?.arguments || {};
      if (toolName === "install_mcp_server" || toolName === "connect_mcp_server") {
        try {
          const result = await handleInstall(args.serverName, args.userEmail);
          sendResponse({
            jsonrpc: "2.0",
            id,
            result
          });
        } catch (installErr) {
          sendResponse({
            jsonrpc: "2.0",
            id,
            result: {
              isError: true,
              content: [
                {
                  type: "text",
                  text: `❌ Αποτυχία εγκατάστασης '${args.serverName}': ${installErr.message}`
                }
              ]
            }
          });
        }
      } else {
        sendResponse({
          jsonrpc: "2.0",
          id,
          error: { code: -32601, message: `Method not found: ${toolName}` }
        });
      }
    } else if (id !== undefined) {
      sendResponse({ jsonrpc: "2.0", id, result: {} });
    }
  } catch (err) {
    console.error("RPC Error:", err.message);
  }
});
