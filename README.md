# OpenAccs

[![Latest release](https://img.shields.io/github/v/release/mikwiseman/openaccs?label=release&color=111)](https://github.com/mikwiseman/openaccs/releases/latest)
[![macOS 26 or later](https://img.shields.io/badge/macOS-26%2B-111)](#requirements)
[![MIT license](https://img.shields.io/badge/license-MIT-111)](LICENSE)

OpenAccs is a free, open-source macOS menu bar app and command-line tool that switches between several Claude and Codex (ChatGPT) accounts, shares one Claude Code history across your Claude accounts, and shows how much is left of the usage limits of Claude, Claude Code, Codex, Grok, Kimi Code and the Z.ai GLM Coding Plan.

Each Claude account runs as its own Claude desktop profile. Every profile uses the same `~/.claude` folder, so your Claude Code settings, skills and sessions are the same on every account. You switch Codex accounts from the same panel, and the switch covers the ChatGPT app and the `codex` CLI together. OpenAccs never reads or copies your Claude login.

<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/images/panel-dark.png">
    <img src="docs/images/panel-light.png" width="340" alt="The OpenAccs menu bar panel. Two Claude accounts and two Codex accounts show how much is left of their 5-hour and weekly limits, with reset times. One Claude limit is empty and comes back in 1h 12m. Below them, Grok, Z.ai and Kimi show their limits.">
  </picture>
</p>

<p align="center"><a href="https://github.com/mikwiseman/openaccs/releases/latest">Download the latest release</a> for macOS 26 or later on Apple silicon and Intel.</p>

## What OpenAccs does

### Use several Claude accounts in the Claude desktop app

The Claude desktop app shows one account at a time. OpenAccs gives each Claude account its own Claude profile, which is a separate Claude data folder with its own sign-in. When you click an account in the panel, OpenAccs opens Claude on that profile, or brings its window forward if it's already open. Several accounts can be open side by side, and you sign in to each profile once, inside Claude itself.

### Share Claude Code history between Claude accounts

Every profile that OpenAccs opens uses the same `~/.claude` folder. Claude Code keeps its settings, skills, `CLAUDE.md`, MCP servers, memory and session transcripts there, so all your Claude accounts work with one setup and one history.

The Code tab in the Claude app lists only the sessions of the account that is signed in. OpenAccs adds each session to the Code tab of your other profiles, so you can start a task on one account and continue it on another when the first account reaches its limit.

- Archived sessions, the permission mode, the effort, Ultracode and the model of each session are the same everywhere. The last change wins, in whichever window you make it.
- Each window keeps its own pinned chats. To pin the same chats everywhere, turn on Settings → General → Sync pinned chats. Turning it on keeps every pin from every window.
- The Claude app's own settings are the same in every window too: its preferences, the permission mode of each folder, how new sessions start (model, effort and fast mode) and the chat MCP servers. Change one in any window and the others take it. The first time, every window takes the default window's settings and keeps the folder modes of all of them. A new window starts with them.
- The sidebar's layout (group by, sort, show) is the one setting OpenAccs leaves alone: Claude keeps it per account on its own servers and puts it back at every launch. Set it once in each account; every window of that account then has it.
- Every account you have signed in to in a window gets the same list, so signing in to another account inside one window shows the same sessions too.
- A profile that is closed shows everything the next time it opens.
- A profile that is open reads its session list only when it starts. When you switch to it from OpenAccs and nothing is running in it, OpenAccs restarts it so it shows the latest list. While a session is working there, OpenAccs only brings it forward and shows what's waiting, like "3 new sessions, 2 changed", with a Restart link.
- If a window is now signed in to another account than the one you added it with, the row says so, for example "Signed in as ai42@waiwai.is".
- A session you delete in one account is not added back to the others.

### Switch Codex accounts in the ChatGPT app and the codex CLI

Codex lives in the ChatGPT desktop app. The app and every `codex` CLI read the same sign-in file, `~/.codex/auth.json`. OpenAccs keeps a copy of each Codex sign-in in the macOS Keychain and switches accounts by swapping that file.

A running Codex keeps its account in memory, so OpenAccs quits the ChatGPT app before the swap and opens it again afterwards. Then it checks that Codex came back on the account you chose. Your local Codex history stays in place, because Codex doesn't split it by account. Cloud tasks, connectors and chats belong to each account and change with it.

### One setup for Claude and Codex

Settings → Setup shows what Claude and Codex share and what differs, from the files themselves, and fixes it with one click:

- **Instructions.** One file, `~/.claude/CLAUDE.md`. Codex reads it through a link at `~/.codex/AGENTS.md`, so there is nothing to keep in sync.
- **Skills.** Stored once in `~/.agents/skills`, which Codex reads; Claude gets a link per skill in `~/.claude/skills`.
- **MCP servers.** The same servers in Claude Code and Codex, translated between their formats field by field. Keys stay as `${VAR}` references; a key written into a file is never copied.
- **Defaults.** Recommended settings for both: autonomy, keeping chats, hiding `.env` and logins from agents.

Nothing changes until you review the plan and apply it. Each change goes to History with Undo, and old files go to Backups first. Logins, connectors and account skills are never copied. If ChatGPT's own Import copies Claude into Codex, the Setup tab offers to turn it off and to remove what it copied.

The Instructions window edits your file, shows instruction files that people publish (with their licenses), adopts the rules you pick into your file through your own Claude Code, and has a six-question wizard for a short file of your own.

From the terminal: `openaccs setup`, `openaccs setup apply [--dry-run]`, `openaccs setup history` and `openaccs setup undo <n>`.

For a Linux server, preview with `openaccs vps user@host --dry-run`, then run `openaccs vps user@host` to install the tools and copy the portable setup. Use a non-root SSH user. Each tool signs in on the server itself; Mac logins and literal keys stay on the Mac. Codex device-code login must be enabled for that account.

### See usage limits for Claude, Codex, Grok, Kimi and Z.ai

Each account row shows how much is left of each limit and when it resets. A full bar means the limit is untouched, and it empties as you use it. A bar turns orange when 20% or less is left. An empty limit shows "Empty" in red and when it comes back. A small star (✦) marks the account with the most left for each product, or, when all of them are empty, the one that comes back first. The menu bar icon has two rings for what's left of the 5-hour and weekly limits of the Claude account you used last.

| Provider | What OpenAccs shows | How you connect it |
| --- | --- | --- |
| Claude | The 5-hour and weekly limits Claude last saved, with the measurement's age. An existing Claude Code sign-in adds live updates every 5 minutes, reset times, plan and extra usage spend. | Automatic for known desktop accounts and matching Claude Code sign-ins. [Connect live limits](#connect-live-claude-limits) is optional. One sign-in covers every window of that account. |
| Codex | What's left of the 5-hour and weekly limits with reset times, a monthly limit for credit-based workspaces, your credit balance and banked limit resets. | Your Codex sign-in. OpenAccs reads the same numbers the Codex app shows, from ChatGPT's usage endpoint. |
| Grok | What's left of the weekly limit, reset time and plan. | The Grok Bot app's local cache, with no sign-in and no network. Or the official Grok CLI for SuperGrok and Grok Build, which is experimental. |
| Kimi Code | What's left of the 5-hour, weekly and monthly limits with reset times, your plan and the extra usage wallet. | A Kimi Code API key. |
| Z.ai GLM Coding Plan | What's left of the 5-hour and weekly limits with reset times, and your plan. | A Z.ai API key, or a BigModel key in China. |

OpenAccs reads local files every minute and asks providers and CLIs every 5 to 15 minutes. To update now, choose Refresh in the More menu (the three dots).

## Privacy and safety

- **Claude.** OpenAccs never reads, stores or copies Claude credentials. Each desktop profile keeps its own sign-in. OpenAccs reads only its non-secret usage history and account identity, never Claude's encrypted `config.json`. For live limits it runs Anthropic's unmodified `claude` CLI with an existing matching sign-in, including the normal terminal sign-in. Optional new connections use the CLI's own browser login and separate folder.
- **Codex.** OpenAccs keeps each saved Codex sign-in in the macOS Keychain, never in a plain file. The active sign-in stays in `~/.codex/auth.json`, where Codex keeps it anyway. OpenAccs renews the tokens of saved accounts that aren't active through OpenAI's own sign-in server, and it leaves the active sign-in to Codex.
- **API keys.** OpenAccs keeps Kimi and Z.ai keys in the macOS Keychain. It checks each key with the provider before it saves it, so a mistyped key never becomes an account.
- **Network.** OpenAccs has no analytics and no telemetry. Once a day it checks for updates at `mikwiseman.github.io` (a feed signed with the OpenAccs key; turn this off in Settings), and every update asks before it installs. While the Instructions window is open, it loads the gallery from `mikwiseman.github.io` and the files in it from `raw.githubusercontent.com`. Otherwise it talks only to `chatgpt.com` and `auth.openai.com` for Codex, `api.kimi.com` or `api.kimi.ai` for Kimi, and `api.z.ai` or `open.bigmodel.cn` for Z.ai. The Claude and Grok CLIs talk to their own servers themselves.
- **Command line.** The `openaccs` command talks to the app over a socket in `~/Library/Application Support/OpenAccs/`, which only your user account can open. Keys you add from the terminal are read from stdin and never written to logs.
- **Your files.** Every write is atomic, so a crash never leaves a half-written file. OpenAccs never edits a file that a running app is using. Before it replaces or removes anything, it copies the old version to `~/Library/Application Support/OpenAccs/Backups/`.
- **Sign-outs.** OpenAccs never signs out of anything. Removing an account removes it from OpenAccs only, and the Claude profile and its history stay on disk. Signing out of Codex would revoke that sign-in everywhere, so OpenAccs never does it.

OpenAccs keeps its own data in `~/Library/Application Support/OpenAccs/`. The file `accounts.json` holds account names and colors and no secrets.

## Install

### Requirements

- macOS 26 (Tahoe) or later, on Apple silicon or Intel.
- The Claude desktop app in `/Applications`, for Claude accounts.
- The ChatGPT desktop app with Codex in `/Applications`, for Codex accounts.
- Claude Code, for live Claude limits. OpenAccs uses `~/.local/bin/claude`, or the copy of Claude Code that the Claude app downloads.
- The Grok Bot app or the Grok CLI, if you want Grok limits.

### Download

In Terminal, one command:

```sh
curl -fsSL https://mikwiseman.github.io/openaccs/install.sh | sh
```

It takes the newest release, checks that Apple notarized it and that it is signed by OpenAccs's developer, moves it to Applications and opens it. Or by hand:

1. Download `OpenAccs-<version>.zip` from [GitHub Releases](https://github.com/mikwiseman/openaccs/releases/latest).
2. Unzip it and move `OpenAccs.app` to your Applications folder.
3. Open OpenAccs. Its icon appears in the menu bar, and it has no Dock icon.

The app is signed with a Developer ID and notarized by Apple. On first launch, OpenAccs adds the Claude profile, the Codex sign-in and the Grok Bot account that it finds on your Mac. To start OpenAccs when you log in, turn on Launch at login in Settings (More menu → Settings…). OpenAccs updates itself from then on.

### Build from source

You need Xcode 26 or later and [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```sh
brew install xcodegen
git clone https://github.com/mikwiseman/openaccs.git
cd openaccs
xcodegen generate
open OpenAccs.xcodeproj
```

You can also build from the command line.

```sh
xcodebuild -project OpenAccs.xcodeproj -scheme OpenAccs -configuration Release build
```

Local builds are signed to run on your own Mac. To run the tests of one package target, pass its name (`OpenAccsCore`, `ClaudeKit`, `CodexKit` or `LimitsKit`) to the test script.

```sh
scripts/test-kit.sh ClaudeKit
```

To check the panel without clicking, render it to a PNG. The `--demo` flag uses sample accounts, and `--dark` uses dark mode.

```sh
/path/to/OpenAccs.app/Contents/MacOS/OpenAccs --snapshot panel.png --demo --dark
```

For maintainers, `scripts/release.sh` builds the app, signs it with a Developer ID, notarizes and staples it, and writes `build/OpenAccs-<version>.zip`. It needs a Developer ID Application certificate (set `TEAM_ID` to your team) and an App Store Connect API key in `~/.appstoreconnect/config.json`. Set `NOTARIZE=0` to skip notarization.

| Folder | What it holds |
| --- | --- |
| `OpenAccs/` | The menu bar app, its SwiftUI panel and the app model. |
| `Packages/OpenAccsKit/` | `OpenAccsCore` (accounts, Keychain, atomic files, processes), `ClaudeKit` (profiles, session sharing, Claude limits), `CodexKit` (Codex switching and limits) and `LimitsKit` (Grok, Kimi and Z.ai). |
| `scripts/` | The test, release and icon scripts. |
| [`DESIGN.md`](DESIGN.md) | The principles, the architecture and the facts about each app that the design rests on. |

## How to use it

### Add a Claude account

1. Click Add at the bottom of the panel and choose Claude.
2. Type a name, e.g. "Work", and click Open Claude. OpenAccs creates a new profile and opens a new Claude window for it.
3. In that window, choose Continue with email and type the code that Anthropic sends you.

Avoid Google sign-in while another Claude window is open, because the sign-in link goes to the Claude window that opened first. Each new profile also downloads about 12 GB for Cowork.

<p align="center"><img src="docs/images/add-claude.png" width="340" alt="The Add Claude view, with a name field, sign-in tips and an Open Claude button."></p>

### Switch Codex accounts

1. Click Add and choose Codex, then click Sign in with ChatGPT.
2. Sign in in the browser that opens and pick the account you want. OpenAccs runs `codex login` in a private folder, so your current Codex sign-in doesn't change.
3. To switch, click a Codex account in the panel and confirm Restart Codex.

Close any `codex` sessions in Terminal before you switch, because they keep the old account in memory. If you sign in to another account inside Codex itself, OpenAccs notices it and adds it to the panel.

<p align="center"><img src="docs/images/add-codex.png" width="340" alt="The Add Codex view in dark mode, with sign-in tips and a Sign in with ChatGPT button."></p>

### Connect live Claude limits

Claude's saved measurements appear automatically. Their timestamp stays visible, and readings older than 30 minutes fade and stop counting toward the best-account recommendation. Refresh rereads these files; it cannot make Claude record a newer measurement. Reset times appear only when known.

OpenAccs also discovers your existing Claude Code sign-in. To add live polling for another account:

1. Open the account's **…** menu and choose **Connect live limits…**.
2. OpenAccs names the windows that use that account. Click Sign in.
3. Anthropic's sign-in page for Claude Code opens in a private window of your browser (Chrome, Brave, Edge or Firefox). Sign in there with that account.

Private windows share one sign-in, so close any other private windows first and connect one account at a time. Safari and other browsers open the page in a normal window. If claude.ai there says "Unable to access Claude Code", it's signed in to another account. Click Copy link and open the link in a private window.

OpenAccs checks both the account and organization before showing live limits. Every window of that account shares the connection, including windows added later. If it stops answering, the menu returns to dated desktop measurements and keeps Connect available in **…**.

### Add a Kimi Code or Z.ai key

1. Click Add and choose Kimi or Z.ai.
2. Paste the API key and choose Global or China.
3. Click Add. OpenAccs checks the key with the provider before it saves it.

You can create a Kimi Code key in the [Kimi Code console](https://www.kimi.ai/code/console) and a Z.ai key on the [Z.ai API keys page](https://z.ai/manage-apikey/apikey-list). In China, use [kimi.com/code/console](https://www.kimi.com/code/console) for Kimi and [open.bigmodel.cn](https://open.bigmodel.cn) for Z.ai.

### Add Grok

Click Add and choose Grok. If the Grok Bot app is signed in on your Mac, its accounts appear in the list, and you click Add next to one. To use the Grok CLI instead, click Sign in under Grok CLI, and OpenAccs runs `grok login` in a private folder.

### Use OpenAccs from the terminal

OpenAccs installs the `openaccs` command in `~/.local/bin` when that folder exists. The command does everything the panel does, through the running app, so it follows the same rules and needs no extra permissions.

```sh
openaccs                    # what's left on every account, and when it comes back
openaccs best claude        # the Claude account with the most left
openaccs use work           # open the "work" Claude profile, or switch Codex to it
openaccs launch --all --json # open saved Claude profiles; leave running ones untouched
openaccs use --best codex   # switch Codex to the account with the most left
openaccs status --json      # the same data for scripts
```

| Command | What it does |
| --- | --- |
| `openaccs [status] [provider] [--json]` | What's left on every account, and when it comes back. `limits` works too. |
| `openaccs best <provider> [--json]` | The account with the most left. |
| `openaccs use <account> [--yes]` | Claude: open that profile. Codex: switch to it (asks first unless you pass `--yes`). Others: open the usage page. `switch` and `open` work too. |
| `openaccs use --best <provider> [--yes]` | The same, for the account with the most left. |
| `openaccs launch <account>… [--json]` or `openaccs launch --all [--json]` | Open selected or all saved Claude profiles in the background. Running profiles are skipped, even with pending changes. Quote names containing spaces. |
| `openaccs restart <account>` | Restart a Claude profile so it loads new sessions. |
| `openaccs refresh [--json]` | Ask every provider now, then show the status. |
| `openaccs connect <account>` | Connect live Claude limits for that account and all its windows (one Claude Code sign-in in the browser). |
| `openaccs add claude <name>` | Add a Claude profile. Also `add codex`, `add grok`, `add grok-bot`, and `add kimi` or `add zai` with a key (`-` or no key reads it from stdin, out of your shell history; `--china` for China accounts). |
| `openaccs rename <account> <new name>` and `openaccs remove <account> [--yes]` | Rename or remove an account. |

An `<account>` is a name or a unique part of it, `provider:name`, or the number that `status` shows. If OpenAccs isn't running, the command starts it in the background. The exit code is 0 on success, 1 on an error, 2 on a usage mistake and 3 when OpenAccs can't be reached. You can also run the command as `/Applications/OpenAccs.app/Contents/MacOS/OpenAccs cli <command>`.

`launch --json` returns a `results` array with each profile's `id`, `label`, `status` (`opened`, `already_open` or `failed`), and `pid` or `error`. Repeated or concurrent commands keep one process per profile. The whole selection is checked before launch; one launch failure doesn't stop the remaining profiles.

### Manage accounts

Open an account's **…** menu to rename it, change its color or remove it. Removal asks you to confirm the named account. Removing Claude leaves its profile and shared history on disk. Its menu also offers Show Data Folder and Restart Claude.

New Claude profiles hide Claude's menu-bar icon by default; OpenAccs remains in the menu bar. An explicit shared preference is preserved. To change an existing window without restarting, use Claude → Settings → System → Menu bar.

## FAQ

### How do I use two Claude accounts on one Mac at the same time?

Add each account in OpenAccs. Each account gets its own Claude profile, so both can be open at once in separate Claude windows. Click an account in the menu bar panel to bring its window forward.

### How do I switch Claude accounts without logging out?

Click the other account in OpenAccs. Each account stays signed in to its own profile, so you never sign out to switch.

### Can I continue a Claude Code session on another Claude account?

Yes. Every profile shares `~/.claude`, and OpenAccs adds your sessions to the Code tab of every account. When one account reaches its 5-hour or weekly limit, open the same session in another account and continue there. Close the session in the first window before you continue, because two windows writing to one session split the conversation.

### Does OpenAccs change the account of `claude` in my terminal?

No. OpenAccs switches the Claude desktop app only, and the `claude` command keeps its own sign-in. Both use `~/.claude`, so your settings, skills, `CLAUDE.md` and MCP servers are the same everywhere.

### How do I switch accounts in Codex or the ChatGPT app?

Add each ChatGPT account under Codex, then click the one you want and confirm Restart Codex. OpenAccs quits the ChatGPT app, swaps `~/.codex/auth.json` and opens the app again. The `codex` CLI reads the same file, so it switches too.

### Will switching Codex accounts lose my history?

No. Codex keeps local history in `~/.codex` for all accounts, and OpenAccs only replaces `auth.json`. Cloud tasks, connectors and chats belong to each account.

### How do I see when my Claude 5-hour limit resets?

OpenAccs shows Claude's saved measurements automatically, with their age. It reuses an existing matching Claude Code sign-in for live updates. For another account, **… → Connect live limits…** adds optional polling and reset times.

### How do I check my Claude and Codex limits from the terminal?

Run `openaccs`. It prints what's left on every account and when each limit comes back, and `openaccs status --json` gives the same data to scripts.

### How do I check my Codex usage limits?

Add your Codex account. OpenAccs shows what's left of the 5-hour and weekly limits with reset times, your credit balance and your banked resets, which are the same numbers the Codex app shows.

### How do I check my Z.ai GLM Coding Plan usage?

Add your Z.ai API key, or your BigModel key in China. OpenAccs shows what's left of the 5-hour and weekly quota with reset times.

### How do I check my Kimi Code usage?

Add your Kimi Code API key. OpenAccs shows what's left of the 5-hour, weekly and monthly quota with reset times.

### Can I see my Grok usage?

Yes. If the Grok Bot app is signed in on your Mac, OpenAccs reads its weekly usage with no sign-in. The Grok CLI option for SuperGrok and Grok Build is experimental.

### Does OpenAccs see my passwords or tokens?

OpenAccs never sees Claude passwords or tokens. It keeps Codex sign-ins and Kimi and Z.ai keys in the macOS Keychain on your Mac, and it sends each one only to its own provider.

### Does OpenAccs send my data anywhere?

No. OpenAccs has no analytics or telemetry, and it talks only to the providers' own usage and sign-in servers.

### Why does each Claude profile take 12 GB?

Each Claude profile downloads its own copy of the virtual machine that Cowork runs in, which is about 12 GB. OpenAccs shows that cost before you add a profile.

### Does OpenAccs work on Intel Macs or older versions of macOS?

It works on Intel and Apple silicon Macs that run macOS 26 or later. It doesn't run on older versions of macOS.

### How is OpenAccs different from CodexBar?

[CodexBar](https://github.com/steipete/CodexBar) shows usage limits for many AI providers. OpenAccs focuses on switching between several Claude and Codex accounts and on sharing one Claude Code history across them, and it shows limits for five providers.

### Is OpenAccs free?

Yes. OpenAccs is free and open source under the MIT license.

## Limitations

- A Claude window loads shared changes after a restart. Switching can restart an idle window; **… → Restart Claude…** asks first. The coordinator command `launch` never restarts a running profile.
- Don't continue the same session in two Claude windows at once. Both windows write to the same transcript, and the conversation splits into two.
- Claude sign-in links (Google, SSO and the email link) and notification clicks go to the Claude window that opened first. Use Continue with email and the code when another Claude window is open.
- Every Claude window has the same icon in the Dock and in the app switcher. Use OpenAccs to pick the right one.
- Each Claude profile downloads its own Cowork virtual machine of about 12 GB.
- Claude's saved measurements can be hours old and contain no reset times. OpenAccs labels their age, fades old readings and drops a window after its duration passes. Live polling needs a matching Claude Code sign-in; it never copies desktop credentials.
- A Codex switch quits and reopens the ChatGPT app. OpenAccs won't switch while a `codex` session runs in Terminal, because that session would keep the old account.
- OpenAccs switches only Codex sign-ins stored in `~/.codex/auth.json`. It won't switch when Codex keeps its sign-in in the keychain (`cli_auth_credentials_store` in `~/.codex/config.toml`) or in `~/.codex/secrets`.
- The Grok CLI option relies on an undocumented billing call, so it is experimental.
- Kimi Code and Z.ai support has been checked against their documented API responses only.
- OpenAccs expects `Claude.app` and `ChatGPT.app` in `/Applications`.

## Not affiliated

OpenAccs is an independent project. It is not affiliated with, endorsed by or sponsored by Anthropic, OpenAI, xAI, Moonshot AI or Zhipu AI (Z.ai). Claude, Claude Code, Codex, ChatGPT, Grok, Kimi, GLM and Z.ai are trademarks of their owners.

## Credits

OpenAccs used [CodexBar](https://github.com/steipete/CodexBar) by Peter Steinberger (MIT license) as a reference for the provider usage endpoints.

## License

OpenAccs is released under the [MIT license](LICENSE). Copyright 2026 Mik Wiseman.
