import Foundation
import Testing
@testable import SetupKit

private let projects = (1...24).map { "[projects.\"/Users/me/Code/project \($0)\"]\ntrust_level = \"trusted\"\n" }.joined(separator: "\n")
private let skills = (1...8).map { "[[skills.config]]\npath = \"/Users/me/.agents/skills/skill-\($0)/SKILL.md\"\nenabled = false\n" }.joined(separator: "\n")

/// Shaped like a real ~/.codex/config.toml (its tables, key styles and kinds of servers), with made-up values.
private let codexConfig = #"""
    # Written by Codex and the ChatGPT app, and edited by hand.
    suppress_unstable_features_warning = true
    model = "gpt-test"
    model_reasoning_effort = "high"   # set by hand
    approval_policy = "never"
    sandbox_mode = "workspace-write"
    notify = [ "/Applications/Notifier.app/Contents/MacOS/notify", "turn-ended" ]
    service_tier = "fast"

    [features]
    multi_agent = true
    memories = true
    mentions_v2 = false

    \#(projects)
    [mcp_servers.figma]
    url = "https://figma.example.com/mcp"

    [mcp_servers.playwright]
    command = "npx"
    args = [ "-y", "@playwright/mcp@latest", "--browser", "--headless" ]
    cwd = "/Users/me/.codex"
    startup_timeout_sec = 60

    [mcp_servers.playwright.env]
    NPM_CONFIG_REGISTRY = "https://registry.example.com/"

    [mcp_servers.node_repl]
    args = []
    command = "/Applications/Example.app/Contents/Resources/node_repl"
    env_vars = ["NODE_REPL_ONE", "NODE_REPL_TWO", "BROWSER_USE_ACCESS_VERIFYING_IDENTITY"]
    startup_timeout_sec = 30

    [mcp_servers.node_repl.env]
    NODE_REPL_NODE_PATH = "/placeholder/node"
    NODE_REPL_TRUSTED_SERVICES = '{"services":["placeholder"]}'
    CODEX_HOME = "/Users/me/.codex"

    [mcp_servers.telegram]
    url = "https://telegram.example.com/mcp"
    bearer_token_env_var = "TELEGRAM_TOKEN"

    [mcp_servers.telegram.tools.search_chats]
    approval_mode = "approve"

    [mcp_servers.google-analytics]
    command = "pipx"
    args = [ "run", "--spec", "placeholder-analytics", "analytics-mcp" ]

    [mcp_servers.google-analytics.env]
    GOOGLE_APPLICATION_CREDENTIALS = "/placeholder/credentials.json"
    GOOGLE_PROJECT_ID = "placeholder-project"

    [mcp_servers.computer-use]
    command = "/Applications/Example.app/Contents/Resources/computer-use"
    args = [ "mcp" ]
    cwd = "."
    enabled = false

    [mcp_servers.unipile]
    url = "https://unipile.example.com/mcp"

    [mcp_servers.unipile.env_http_headers]
    X-API-KEY = "UNIPILE_API_KEY"

    [mcp_servers.company]
    url = "https://company.example.com/mcp"
    http_headers_helper = "/Users/me/bin/company-headers"
    tool_timeout_sec = 120
    disabled_tools = [ "meeting_create" ]

    [mcp_servers.stripe]
    url = "https://stripe.example.com/mcp"
    env_http_headers = { Authorization = "STRIPE_AUTHORIZATION" }
    http_headers = { "X-Client-Name" = "placeholder" }

    # Pinned by hand.
    [mcp_servers.xcode]
    command = "npx"
    args = [
      "-y",
      "xcodebuildmcp@1.0.0",   # this version works
      "mcp",
    ]
    enabled_tools = ["build_sim", "test_sim"]
    env = { XCODEBUILDMCP_ENABLED_WORKFLOWS = "simulator,ui-automation" }

    \#(skills)
    [notice]
    fast_default_opt_out = true

    [notice.model_migrations]
    "gpt-5.1-codex-max" = "gpt-test"
    "gpt-5.2" = "gpt-test"

    [tui]
    status_line = [ "model", "context-remaining", "fast-mode" ]
    screen_reader_detection_done = true

    [tui.model_availability_nux]
    "gpt-5.5" = 1
    gpt-6-astra = 3

    [plugins."gmail@openai-curated"]
    enabled = true

    [plugins."documents@openai-primary-runtime"]
    enabled = false

    [marketplaces.openai-bundled]
    source_type = "local"
    source = "/Applications/Example.app/Contents/Resources/marketplace"

    [desktop]
    followUpQueueMode = "queue"
    dock-icon-preference = "menu-bar"
    selected-avatar-id = "placeholder-avatar"
    hotkey-window-projectless-default-enabled = true
    enabled-reasoning-efforts = [ "low", "medium", "high", "max" ]
    show-context-window-usage = true
    dictationDictionary = []
    avatar-overlay-mascot-width-px = 96
    mac-menu-bar-enabled = false

    [desktop.open-in-target-preferences]
    global = "vscode"

    [desktop.open-in-target-preferences.perPath]
    "/Users/me/Code/project 1" = "cursor"

    [shell_environment_policy]
    inherit = "core"

    [shell_environment_policy.set]
    PATH = "/placeholder/bin:/usr/bin:/bin"

    """#

private let realConfig = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".codex/config.toml")

/// `text` with `old`, which must appear exactly once, replaced by `new`.
private func replacingOnce(_ text: String, _ old: String, _ new: String) -> String {
    let parts = text.components(separatedBy: old)
    #expect(parts.count == 2, "expected one \(old.debugDescription)")
    return parts.joined(separator: new)
}

/// Edits are checked with `== true`: #expect can't call a mutating method on its own.
@Suite struct TOMLFileTests {
    @Test func readsTheSubsetCodexUses() throws {
        let file = try #require(TOMLFile(text: #"""
            # A comment line
            title = "Basic \"quoted\" \\ \t tab \u00E9 \U0001F600"
            literal = 'C:\Users\no\escapes'
            multi = """
            Roses are red
            Violets are blue"""
            folded = """\
                The quick \
                brown fox."""
            raw = '''
            first line
              'quoted' second'''
            int = +1_000
            negative = -17
            hex = 0xDEAD_beef
            octal = 0o755
            binary = 0b1101
            float = 6.626e-34
            pi = 3.1415
            infinite = -inf
            yes = true
            no = false
            empty = []
            nested = [ [1, 2], ["a", 'b'] ]
            long = [
              "one",   # first
              # a whole comment line
              "two",
            ]
            point = { x = 1, y = 2.5, label.text = "here" }
            site."google.com".visits = 3
            "quoted key" = "q"
            'literal key' = 'l'

            [a.b."c d"]   # a header comment
            e = 1
            [a]
            f = 2
            """#))

        #expect(file.value("title", in: []) == .string("Basic \"quoted\" \\ \t tab é 😀"))
        #expect(file.value("literal", in: []) == .string(#"C:\Users\no\escapes"#))
        #expect(file.value("multi", in: []) == .string("Roses are red\nViolets are blue"))
        #expect(file.value("folded", in: []) == .string("The quick brown fox."))
        #expect(file.value("raw", in: []) == .string("first line\n  'quoted' second"))
        #expect(file.value("int", in: []) == .integer(1000))
        #expect(file.value("negative", in: []) == .integer(-17))
        #expect(file.value("hex", in: []) == .integer(0xDEADBEEF))
        #expect(file.value("octal", in: []) == .integer(0o755))
        #expect(file.value("binary", in: []) == .integer(0b1101))
        #expect(file.value("float", in: []) == .float(6.626e-34))
        #expect(file.value("pi", in: []) == .float(3.1415))
        #expect(file.value("infinite", in: []) == .float(-.infinity))
        #expect(file.value("yes", in: []) == .bool(true))
        #expect(file.value("no", in: []) == .bool(false))
        #expect(file.value("empty", in: []) == .array([]))
        #expect(file.value("nested", in: []) == .array([.array([.integer(1), .integer(2)]), .array([.string("a"), .string("b")])]))
        #expect(file.value("long", in: []) == .array([.string("one"), .string("two")]))
        #expect(file.value("point", in: []) == .table(["x": .integer(1), "y": .float(2.5), "label": .table(["text": .string("here")])]))
        #expect(file.value("visits", in: ["site", "google.com"]) == .integer(3))
        #expect(file.value("quoted key", in: []) == .string("q"))
        #expect(file.value("literal key", in: []) == .string("l"))
        #expect(file.value("e", in: ["a", "b", "c d"]) == .integer(1))
        #expect(file.value("f", in: ["a"]) == .integer(2))
        #expect(file.value("missing", in: []) == nil)
        #expect(file.value("e", in: ["nowhere"]) == nil)
    }

    @Test(arguments: [
        "a = 1\na = 2",                      // a key twice
        "[a]\n[a]",                          // a table twice
        "b = 1\n[b]",                         // a value reopened as a table
        "p = { x = 1 }\np.y = 2",            // a key added to an inline table
        "p = { x = 1 }\n[p.q]",
        "[[t]]\n[t]",                        // an array of tables reopened as a table
        "d = 1979-05-27",                    // dates: Codex never writes them
        "big = 9223372036854775808",         // too big for Int
        "s = \"unterminated",
        "s = \"bad \\q escape\"",
        "k = ",
        "= 1",
        "[a",
        "x = 1 y = 2",
        "list = [1, 2",
    ])
    func refusesWhatItCannotReadExactly(_ text: String) {
        #expect(TOMLFile(text: text) == nil)
    }

    @Test func listsServersWithAllTheirTablesMerged() throws {
        let file = try #require(TOMLFile(text: #"""
            [mcp_servers.alpha]
            command = "npx"
            args = ["-y", "alpha"]
            env = { TOKEN_NAME = "ALPHA_TOKEN" }

            [mcp_servers.beta]
            url = "https://beta.example.com/mcp"
            bearer_token_env_var = "BETA_TOKEN"

            [mcp_servers.beta.env]
            A = "1"

            [mcp_servers.beta.tools.search]
            approval_mode = "approve"

            [mcp_servers]
            gamma = { url = "https://gamma.example.com/mcp" }

            [mcp_servers."delta.one"]
            url = "https://delta.example.com/mcp"
            """#))

        #expect(file.mcpServers == [
            "alpha": .table(["command": .string("npx"), "args": .array([.string("-y"), .string("alpha")]),
                             "env": .table(["TOKEN_NAME": .string("ALPHA_TOKEN")])]),
            "beta": .table(["url": .string("https://beta.example.com/mcp"), "bearer_token_env_var": .string("BETA_TOKEN"),
                            "env": .table(["A": .string("1")]),
                            "tools": .table(["search": .table(["approval_mode": .string("approve")])])]),
            "gamma": .table(["url": .string("https://gamma.example.com/mcp")]),
            "delta.one": .table(["url": .string("https://delta.example.com/mcp")]),
        ])
        #expect(try #require(TOMLFile(text: "model = \"x\"\n")).mcpServers.isEmpty)
    }

    @Test func rendersInSortedOrderAndReadsBackTheSame() throws {
        let server: [String: TOMLValue] = [
            "command": .string("npx"),
            "args": .array([.string("-y"), .string("say \"hi\"\n")]),
            "enabled": .bool(false),
            "startup_timeout_sec": .integer(30),
            "ratio": .float(0.5),
            "env": .table(["B": .string("2"), "A": .string("1")]),
            "env_http_headers": .table([:]),
            "tools": .table(["search": .table(["approval_mode": .string("approve")])]),
            "two words": .table(["x": .integer(1)]),
        ]
        let text = TOMLFile.render(server, at: ["mcp_servers", "x"])
        #expect(text == #"""
            [mcp_servers.x]
            args = ["-y", "say \"hi\"\n"]
            command = "npx"
            enabled = false
            ratio = 0.5
            startup_timeout_sec = 30

            [mcp_servers.x.env]
            A = "1"
            B = "2"

            [mcp_servers.x.env_http_headers]

            [mcp_servers.x.tools.search]
            approval_mode = "approve"

            [mcp_servers.x."two words"]
            x = 1

            """#)
        #expect(try #require(TOMLFile(text: text)).mcpServers["x"] == .table(server))

        // Inside arrays and as one key's new value, tables are written inline.
        let inline: TOMLValue = .table(["b": .array([.table(["k": .string("v")])]), "a": .table([:])])
        #expect(TOMLFile.inline(inline) == "{ a = {}, b = [{ k = \"v\" }] }")
    }

    @Test func editsLeaveEveryOtherByteOfARealShapedConfigAlone() throws {
        var file = try #require(TOMLFile(text: codexConfig))
        var analytics = try #require(file.mcpServers["google-analytics"]?.table)
        analytics["enabled"] = .bool(false)

        #expect(file.setServer("google-analytics", .table(analytics)) == true)
        #expect(file.set("personality", .string("pragmatic"), in: []) == true)
        #expect(file.set("dock-icon-preference", .string("dock"), in: ["desktop"]) == true)

        var expected = replacingOnce(codexConfig, """
            [mcp_servers.google-analytics]
            command = "pipx"
            args = [ "run", "--spec", "placeholder-analytics", "analytics-mcp" ]

            [mcp_servers.google-analytics.env]
            GOOGLE_APPLICATION_CREDENTIALS = "/placeholder/credentials.json"
            GOOGLE_PROJECT_ID = "placeholder-project"

            """, """
            [mcp_servers.google-analytics]
            args = ["run", "--spec", "placeholder-analytics", "analytics-mcp"]
            command = "pipx"
            enabled = false

            [mcp_servers.google-analytics.env]
            GOOGLE_APPLICATION_CREDENTIALS = "/placeholder/credentials.json"
            GOOGLE_PROJECT_ID = "placeholder-project"

            """)
        expected = replacingOnce(expected, "service_tier = \"fast\"\n", "service_tier = \"fast\"\npersonality = \"pragmatic\"\n")
        expected = replacingOnce(expected, "dock-icon-preference = \"menu-bar\"\n", "dock-icon-preference = \"dock\"\n")
        #expect(file.text == expected)
        #expect(codexConfig.split(separator: "\n", omittingEmptySubsequences: false).count > 200)
    }

    @Test func setReplacesOnlyTheValueOfAKeyThatIsThere() throws {
        var file = try #require(TOMLFile(text: codexConfig))
        #expect(file.set("model_reasoning_effort", .string("xhigh"), in: []) == true)
        #expect(file.set("args", .array([.string("-y"), .string("xcodebuildmcp@2.0.0")]), in: ["mcp_servers", "xcode"]) == true)
        #expect(file.set("visits", .integer(4), in: ["site"]) == true)   // a new table, at the end
        var expected = replacingOnce(codexConfig, "model_reasoning_effort = \"high\"   # set by hand\n",
                                     "model_reasoning_effort = \"xhigh\"   # set by hand\n")
        expected = replacingOnce(expected, """
            args = [
              "-y",
              "xcodebuildmcp@1.0.0",   # this version works
              "mcp",
            ]

            """, "args = [\"-y\", \"xcodebuildmcp@2.0.0\"]\n")
        expected += "\n[site]\nvisits = 4\n"
        #expect(file.text == expected)

        let unchanged = file.text
        #expect(file.set("model", .string("gpt-test"), in: []) == true)   // the same value: nothing to write
        #expect(file.text == unchanged)
    }

    @Test func setAddsANewKeyWhereTOMLReadsItAsPartOfThatTable() throws {
        // A top-level key goes before the first header, which would otherwise take it.
        var file = try #require(TOMLFile(text: "# Mine\n[features]\nhooks = true\n"))
        #expect(file.set("model", .string("gpt-test"), in: []) == true)
        #expect(file.text == "model = \"gpt-test\"\n\n# Mine\n[features]\nhooks = true\n")
        #expect(file.value("model", in: []) == .string("gpt-test"))

        // A table's new key goes after its last key, before its sub-tables.
        file = try #require(TOMLFile(text: "[desktop]\na = 1\n# about b\n\n[desktop.sub]\nc = 3\n"))
        #expect(file.set("b-key", .integer(2), in: ["desktop"]) == true)
        #expect(file.text == "[desktop]\na = 1\nb-key = 2\n# about b\n\n[desktop.sub]\nc = 3\n")

        // A table with only its header, a file without a last newline, a missing table, a dotted key.
        file = try #require(TOMLFile(text: "[empty]\n[other]\nx = 1"))
        #expect(file.set("a", .bool(true), in: ["empty"]) == true)
        #expect(file.set("y", .integer(2), in: ["other"]) == true)
        #expect(file.set("token", .string("NAME"), in: ["mcp_servers", "new one", "env"]) == true)
        #expect(file.text == "[empty]\na = true\n[other]\nx = 1\ny = 2\n\n[mcp_servers.\"new one\".env]\ntoken = \"NAME\"\n")

        file = try #require(TOMLFile(text: "site.visits = 1\n"))
        #expect(file.set("visits", .integer(2), in: ["site"]) == true)
        #expect(file.text == "site.visits = 2\n")

        file = try #require(TOMLFile(text: ""))
        #expect(file.set("model", .string("gpt-test"), in: []) == true)
        #expect(file.text == "model = \"gpt-test\"\n")
    }

    @Test func editsThatWouldMeanSomethingElseAreRefused() throws {
        let text = """
            [mcp_servers.x]
            env = { A = "1" }

            [[skills.config]]
            path = "/a"

            [mcp_servers.y.env]
            B = "2"
            """
        var file = try #require(TOMLFile(text: text))
        #expect(file.set("B", .string("2"), in: ["mcp_servers", "x", "env"]) == false)     // inside an inline table
        #expect(file.set("enabled", .bool(false), in: ["skills", "config"]) == false)      // inside an array of tables
        #expect(file.set("env", .table(["C": .string("3")]), in: ["mcp_servers", "y"]) == false)  // a table with a header
        #expect(file.remove("A", in: ["mcp_servers", "x", "env"]) == false)
        #expect(file.remove("env", in: ["mcp_servers", "y"]) == false)
        #expect(file.setServer("x", .string("not a table")) == false)
        #expect(file.text == text)
        #expect(file.remove("nothing", in: ["mcp_servers", "x"]) == true)   // nothing to remove
        #expect(file.text == text)
    }

    @Test func removeTakesOnlyThatKeysLines() throws {
        var file = try #require(TOMLFile(text: codexConfig))
        #expect(file.remove("model_reasoning_effort", in: []) == true)
        #expect(file.remove("args", in: ["mcp_servers", "xcode"]) == true)
        #expect(file.remove("global", in: ["desktop", "open-in-target-preferences"]) == true)
        var expected = replacingOnce(codexConfig, "model_reasoning_effort = \"high\"   # set by hand\n", "")
        expected = replacingOnce(expected, """
            args = [
              "-y",
              "xcodebuildmcp@1.0.0",   # this version works
              "mcp",
            ]

            """, "")
        expected = replacingOnce(expected, "global = \"vscode\"\n", "")
        #expect(file.text == expected)
        #expect(file.value("model_reasoning_effort", in: []) == nil)
    }

    @Test func setServerReplacesAddsAndRemovesAWholeServer() throws {
        var file = try #require(TOMLFile(text: """
            model = "gpt-test"

            [mcp_servers.x]
            url = "https://x.example.com"

            [mcp_servers.y]
            command = "y"

            [mcp_servers.x.env]
            A = "1"

            [mcp_servers.x.tools.search]
            approval_mode = "approve"

            [features]
            hooks = true

            """))
        // Replacing a server whose tables are apart puts all of it where its first table was.
        #expect(file.setServer("x", .table(["url": .string("https://x2.example.com"), "env": .table(["A": .string("2")])])) == true)
        #expect(file.text == """
            model = "gpt-test"

            [mcp_servers.x]
            url = "https://x2.example.com"

            [mcp_servers.x.env]
            A = "2"

            [mcp_servers.y]
            command = "y"

            [features]
            hooks = true

            """)

        // A new server goes after the last one.
        #expect(file.setServer("z", .table(["command": .string("z"), "args": .array([])])) == true)
        #expect(file.text == """
            model = "gpt-test"

            [mcp_servers.x]
            url = "https://x2.example.com"

            [mcp_servers.x.env]
            A = "2"

            [mcp_servers.y]
            command = "y"

            [mcp_servers.z]
            args = []
            command = "z"

            [features]
            hooks = true

            """)

        // Removing one takes its blank line with it, so the spacing around stays the same.
        #expect(file.setServer("x", nil) == true)
        #expect(file.setServer("z", nil) == true)
        #expect(file.text == """
            model = "gpt-test"

            [mcp_servers.y]
            command = "y"

            [features]
            hooks = true

            """)
        #expect(file.setServer("y", nil) == true)
        #expect(file.text == "model = \"gpt-test\"\n\n[features]\nhooks = true\n")
        #expect(file.mcpServers.isEmpty)

        // With no servers yet, the first one goes at the end of the file.
        #expect(file.setServer("a", .table(["url": .string("https://a.example.com")])) == true)
        #expect(file.text == "model = \"gpt-test\"\n\n[features]\nhooks = true\n\n[mcp_servers.a]\nurl = \"https://a.example.com\"\n")
    }

    @Test func setServerMovesAServerWrittenInsideAnotherTableIntoItsOwn() throws {
        var file = try #require(TOMLFile(text: """
            [mcp_servers]
            a = { url = "https://a.example.com" }
            b = { url = "https://b.example.com" }

            [features]
            hooks = true
            """))
        #expect(file.setServer("a", .table(["url": .string("https://a2.example.com")])) == true)
        #expect(file.text == """
            [mcp_servers]
            b = { url = "https://b.example.com" }

            [mcp_servers.a]
            url = "https://a2.example.com"

            [features]
            hooks = true
            """)
        #expect(file.setServer("b", nil) == true)
        #expect(file.mcpServers == ["a": .table(["url": .string("https://a2.example.com")])])
    }

    @Test func aServerEditOnTheRealShapesKeepsEveryOtherServer() throws {
        let file = try #require(TOMLFile(text: codexConfig))
        #expect(file.mcpServers.count == 10)
        #expect(file.mcpServers["xcode"]?.table?["env"] == .table(["XCODEBUILDMCP_ENABLED_WORKFLOWS": .string("simulator,ui-automation")]))
        #expect(file.mcpServers["stripe"]?.table?["env_http_headers"] == .table(["Authorization": .string("STRIPE_AUTHORIZATION")]))
        #expect(file.mcpServers["unipile"]?.table?["env_http_headers"] == .table(["X-API-KEY": .string("UNIPILE_API_KEY")]))
        for (name, value) in file.mcpServers {
            var copy = file
            #expect(copy.setServer(name, nil) == true)
            #expect(copy.mcpServers == file.mcpServers.filter { $0.key != name })
            #expect(copy.setServer(name, value) == true)
            #expect(copy.mcpServers == file.mcpServers)
            #expect(copy.value("trust_level", in: ["projects", "/Users/me/Code/project 24"]) == .string("trusted"))
        }
    }

    /// Reads the Codex config on this Mac, if there is one. It holds secrets, so only counts and yes/no are checked
    /// and nothing from it is ever printed, even when a check fails.
    @Test(.enabled(if: FileManager.default.fileExists(atPath: realConfig.path)))
    func readsTheRealCodexConfig() throws {
        let text = try String(contentsOf: realConfig, encoding: .utf8)
        let parsed = TOMLFile(text: text)
        let didParse = parsed != nil
        #expect(didParse)
        guard var file = parsed else { return }

        let headers = text.matches(of: /^[ \t]*\[[ \t]*mcp_servers[ \t]*\.[ \t]*("[^"]*"|[A-Za-z0-9_-]+)/.anchorsMatchLineEndings())
        let names = Set(headers.map { String($0.output.1).trimmingCharacters(in: CharacterSet(charactersIn: "\"")) })
        #expect(file.mcpServers.count == names.count)
        let sameNames = Set(file.mcpServers.keys) == names
        #expect(sameNames)

        // Adding and then removing a key gives back the very same text.
        let original = file.text
        let added = file.set("openaccs_test_key", .bool(true), in: [])
        let removed = file.remove("openaccs_test_key", in: [])
        let sameText = file.text == original
        #expect(added && removed && sameText)

        // Each server comes out and goes back without touching any other value.
        let servers = file.mcpServers
        var editedAll = true
        for (name, value) in servers {
            var copy = file
            editedAll = editedAll && copy.setServer(name, nil) && copy.mcpServers.count == servers.count - 1
                && copy.setServer(name, value) && copy.mcpServers == servers
        }
        #expect(editedAll)
    }
}
