# frozen_string_literal: true

# Shared library for `bin/doctor.rb` (read-only) and `bin/bootstrap-fork.rb`
# (idempotent driver). Reads `.bootstrap.env`, validates config, exposes a
# pipeline of 19 step classes. CI mode runs 18 steps with default
# PLATFORMS=ios,macos; local mode runs 14. Each step has a `check`
# (returns bool, no side effects)
# and a `do_it` (idempotent: safe to re-run on partial state).
#
# Doctor mode just calls every `check` and reports.
# Bootstrap mode calls `check || do_it` per step and stops on first failure.
#
# Steps that can't be automated (Apple disallows POST /apps + API key creation,
# GitHub disallows programmatic PAT creation) fail loud in `do_it` with
# explicit web-UI instructions.

require "base64"
require "digest"
require "fileutils"
require "json"
require "open3"
require "pathname"
require "securerandom"
require "shellwords"
require "tmpdir"

module Bootstrap
  REPO_ROOT = Pathname.new(__dir__).join("..", "..").expand_path
  ENV_FILE  = REPO_ROOT.join(".bootstrap.env")

  # The 7 GH Secrets the release pipeline needs. Order: stable for doctor.
  REQUIRED_SECRETS = %w[
    MATCH_PASSWORD
    MATCH_GIT_BASIC_AUTHORIZATION
    KEYCHAIN_PASSWORD
    ASC_API_KEY_ID
    ASC_API_KEY_ISSUER_ID
    ASC_API_KEY_P8_BASE64
    FASTLANE_TEAM_ID
  ].freeze

  # ─── Config loader ──────────────────────────────────────────────────────────

  class Config
    REQUIRED_ALWAYS = %w[
      APP_NAME BUNDLE_ID DISPLAY_NAME APP_EMAIL GENERATOR RELEASE_MODE
      FASTLANE_TEAM_ID ASC_API_KEY_ID ASC_API_KEY_ISSUER_ID ASC_API_KEY_P8_PATH
      GH_ORG GH_APP_REPO
    ].freeze

    REQUIRED_CI_ONLY = %w[
      GH_CERTS_REPO GH_PAT_FILE MATCH_PASSWORD_FILE KEYCHAIN_PASSWORD_FILE
    ].freeze

    OPTIONAL = %w[ICON_1024_PATH ASC_APP_SKU ASC_APP_NAME PLATFORMS].freeze

    attr_reader :values

    def self.load!
      env_file = ENV_FILE
      unless env_file.exist?
        UI.fail!(<<~MSG)
          .bootstrap.env not found at #{env_file}.

          Copy the example and fill in your values:
            cp .bootstrap.env.example .bootstrap.env
            $EDITOR .bootstrap.env

          See docs/BOOTSTRAP.md for what each field means and where to source it.
        MSG
      end
      new(parse(env_file))
    end

    def self.parse(path)
      values = {}
      path.each_line.with_index do |line, idx|
        line = line.strip
        next if line.empty? || line.start_with?("#")
        key, _, val = line.partition("=")
        UI.fail!(".bootstrap.env line #{idx + 1}: missing '='") if val.nil? || key.strip.empty?
        val = val.strip
        if val.start_with?("'") || val.start_with?('"')
          # Quoted value. Find the matching closing quote; the value is
          # exactly what's between the two quotes. Anything after the
          # closing quote (typically `  # trailing comment`) is discarded.
          # We deliberately do NOT honor backslash escapes here — `.bootstrap.env`
          # values are paths, ids, and short strings, never multi-line literals.
          quote_char = val[0]
          closing = val.index(quote_char, 1)
          val = closing ? val[1...closing] : val
        elsif (comment_at = val.index(/(?:^|\s)#/))
          # Unquoted value with an inline comment. Strip everything from the
          # first whitespace-hash onward (dotenv convention). Bare '#' inside
          # an unquoted value (e.g. URL fragments) is preserved because it
          # has no preceding whitespace. The (?:^|\s) form also matches a
          # value that's purely a comment (`KEY=  # only-a-comment`) — strip
          # to the empty string.
          # The .bootstrap.env.example template ships every fillable field
          # with an inline `# placeholder` comment; without this strip, a
          # forker who fills `BUNDLE_ID=com.foo.bar` while leaving the
          # trailing `# iOS + macOS share the same bundle id.` comment
          # would have that comment text mashed onto the bundle id, breaking
          # every downstream Apple/GH probe.
          val = val[0...comment_at].rstrip
        end
        values[key.strip] = val
      end
      values
    end

    def initialize(values)
      @values = values
    end

    def [](key)
      @values[key].to_s
    end

    def set?(key)
      v = @values[key]
      !v.nil? && !v.strip.empty?
    end

    def expand_path(key)
      raw = self[key]
      return nil if raw.empty?
      Pathname.new(raw).expand_path
    end

    def validate!
      mode = release_mode
      unless %w[ci local].include?(mode)
        UI.fail!(".bootstrap.env: RELEASE_MODE must be 'ci' or 'local' (got: #{mode.inspect})")
      end
      validate_platforms!
      required = REQUIRED_ALWAYS + (mode == "ci" ? REQUIRED_CI_ONLY : [])
      missing = required.reject { |k| set?(k) }
      return if missing.empty?

      # Common onboarding trap: users transcribe the unsuffixed name
      # (MATCH_PASSWORD, KEYCHAIN_PASSWORD, GH_PAT) instead of the path
      # form (MATCH_PASSWORD_FILE, etc.) that .bootstrap.env expects.
      # The unsuffixed name is what fastlane/gh internally consume —
      # natural to type, wrong to set here. If the user has the path-less
      # variant present, point them at the rename.
      hints = []
      missing.each do |key|
        next unless key.end_with?("_FILE")
        unsuffixed = key.sub(/_FILE\z/, "")
        next unless set?(unsuffixed)
        hints << "  - rename `#{unsuffixed}=` to `#{key}=` (the *_FILE suffix denotes a path; bootstrap reads the file and exposes #{unsuffixed} to subprocesses)"
      end

      hint_block = hints.empty? ? "" : "\n\nHint:\n#{hints.join("\n")}"

      UI.fail!(<<~MSG)
        .bootstrap.env is missing required fields (RELEASE_MODE=#{mode}):
        #{missing.map { |k| "  - #{k}" }.join("\n")}#{hint_block}

        Edit .bootstrap.env and re-run.
      MSG
    end

    def release_mode
      m = self["RELEASE_MODE"]
      m.empty? ? "ci" : m
    end

    # Returns the active platforms as an array of strings.
    # PLATFORMS=ios          → %w[ios]
    # PLATFORMS=macos        → %w[macos]
    # PLATFORMS=ios,macos    → %w[ios macos]
    # PLATFORMS unset/empty  → %w[ios macos] (default: both, current behavior)
    def platforms
      raw = self["PLATFORMS"].strip
      return %w[ios macos] if raw.empty?
      raw.split(",").map(&:strip).reject(&:empty?)
    end

    def platform_enabled?(platform)
      platforms.include?(platform.to_s)
    end

    def ios?;   platform_enabled?("ios");   end
    def macos?; platform_enabled?("macos"); end

    private

    def validate_platforms!
      valid = %w[ios macos]
      bad = platforms.reject { |p| valid.include?(p) }
      return if bad.empty? && !platforms.empty?
      if platforms.empty?
        UI.fail!(".bootstrap.env: PLATFORMS cannot be empty. Use 'ios', 'macos', or 'ios,macos'.")
      end
      UI.fail!(<<~MSG)
        .bootstrap.env: PLATFORMS contains invalid value(s): #{bad.inspect}
        Valid values: 'ios', 'macos', or comma-separated like 'ios,macos'.
      MSG
    end

    public

    def ci_mode?;    release_mode == "ci";    end
    def local_mode?; release_mode == "local"; end

    def repo_slug
      "#{self["GH_ORG"]}/#{self["GH_APP_REPO"]}"
    end

    def certs_slug
      "#{self["GH_ORG"]}/#{self["GH_CERTS_REPO"]}"
    end

    def certs_url
      "https://github.com/#{certs_slug}.git"
    end
  end

  # ─── UI helpers ─────────────────────────────────────────────────────────────

  module UI
    GREEN  = "\e[32m"
    RED    = "\e[31m"
    YELLOW = "\e[33m"
    DIM    = "\e[2m"
    BOLD   = "\e[1m"
    RESET  = "\e[0m"

    module_function

    def tty?
      $stdout.tty?
    end

    def colorize(text, color)
      tty? ? "#{color}#{text}#{RESET}" : text
    end

    def ok(text); colorize("✓ #{text}", GREEN); end
    def miss(text); colorize("✗ #{text}", RED); end
    def warn(text); colorize("⚠ #{text}", YELLOW); end
    def dim(text); colorize(text, DIM); end
    def bold(text); colorize(text, BOLD); end

    def fail!(msg)
      $stderr.puts colorize("ERROR: #{msg}", RED)
      exit 1
    end

    def section(text)
      puts
      puts bold(text)
      puts colorize("─" * text.length, DIM)
    end

    def step_header(num, total, name)
      puts colorize("[#{num}/#{total}] #{name}", BOLD)
    end
  end

  # ─── Shell + tool helpers ───────────────────────────────────────────────────

  module Sh
    module_function

    # Run a command; raise on non-zero exit.
    def run!(*cmd, env: {}, cwd: REPO_ROOT)
      Dir.chdir(cwd) do
        out, err, status = Open3.capture3(env, *cmd)
        unless status.success?
          UI.fail!("command failed (exit #{status.exitstatus}):\n  #{cmd.join(' ')}\nstdout: #{out}\nstderr: #{err}")
        end
        out
      end
    end

    # Run a command; capture output regardless of exit. Returns [stdout, success?]
    def run(*cmd, env: {}, cwd: REPO_ROOT)
      Dir.chdir(cwd) do
        out, _err, status = Open3.capture3(env, *cmd)
        [out, status.success?]
      end
    end

    # Quiet boolean check.
    def ok?(*cmd, env: {}, cwd: REPO_ROOT)
      _out, success = run(*cmd, env: env, cwd: cwd)
      success
    end
  end

  # ─── Step base class ────────────────────────────────────────────────────────

  class Step
    # Each subclass may override MODES + PLATFORMS to restrict applicability:
    #   class EditMatchfile < Step; MODES = %w[ci]; end           # ci only
    #   class LocalKeychainCerts < Step; MODES = %w[local]; end   # local only
    #   class MintInstaller < Step; PLATFORMS = %w[macos]; end    # macOS only
    # Default: run in any mode and any platform combination.
    MODES = %w[ci local].freeze
    PLATFORMS = %w[ios macos].freeze

    attr_reader :config

    def initialize(config)
      @config = config
    end

    # Step is applicable iff (a) the active mode is in MODES AND
    # (b) at least one of the active platforms is in PLATFORMS.
    def applicable?(mode, active_platforms)
      return false unless self.class.const_get(:MODES).include?(mode)
      step_platforms = self.class.const_get(:PLATFORMS)
      (step_platforms & active_platforms).any?
    end

    # Subclasses override.
    def name; self.class.name.split("::").last; end
    def category; "programmatic"; end
    # check returns one of:
    #   :done            — already in desired state, skip do_it
    #   :pending         — not in desired state, run do_it
    #   [:blocked, msg]  — human-gated, do_it will fail loud with msg
    def check; raise NotImplementedError; end
    def do_it; raise NotImplementedError; end
  end

  # ─── Concrete steps ─────────────────────────────────────────────────────────

  class CheckAppleCreds < Step
    def name; "Apple credentials"; end
    def category; "preflight"; end

    def check
      p8 = config.expand_path("ASC_API_KEY_P8_PATH")
      return [:blocked, "ASC_API_KEY_P8_PATH file does not exist: #{p8}"] unless p8 && p8.file?

      # Probe ASC API by requesting current user
      require "spaceship"
      pem_path = write_p8(p8)
      token = Spaceship::ConnectAPI::Token.create(
        key_id:    config["ASC_API_KEY_ID"],
        issuer_id: config["ASC_API_KEY_ISSUER_ID"],
        filepath:  pem_path
      )
      Spaceship::ConnectAPI.token = token
      apps = Spaceship::ConnectAPI::App.all(limit: 1)
      :done
    rescue StandardError => e
      [:blocked, "ASC API probe failed: #{e.class.name}: #{e.message}"]
    end

    def do_it
      # No automation possible — credentials must be valid.
      UI.fail!("Apple credentials invalid. Fix .bootstrap.env then re-run.")
    end

    private

    def write_p8(src)
      # If src is .p8 PEM, return path. (Spaceship reads PEM from filepath.)
      src.to_s
    end
  end

  class CheckGHCreds < Step
    def name; "GitHub credentials"; end
    def category; "preflight"; end

    def check
      return :done if config.local_mode? # PAT not used in local mode
      pat_file = config.expand_path("GH_PAT_FILE")
      return [:blocked, "GH_PAT_FILE doesn't exist: #{pat_file}"] unless pat_file && pat_file.file?
      pat = pat_file.read.strip
      return [:blocked, "GH_PAT_FILE is empty"] if pat.empty?

      # Probe certs repo via PAT
      out, _ok = Sh.run("curl", "-s", "-o", "/dev/null", "-w", "%{http_code}",
                        "-H", "Authorization: Bearer #{pat}",
                        "-H", "Accept: application/vnd.github+json",
                        "https://api.github.com/repos/#{config.certs_slug}")
      case out
      when "200" then :done
      when "404"
        # PAT might be valid but certs repo missing — that's a separate step.
        # Probe whether PAT itself works on user endpoint.
        out2, _ = Sh.run("curl", "-s", "-o", "/dev/null", "-w", "%{http_code}",
                         "-H", "Authorization: Bearer #{pat}",
                         "https://api.github.com/user")
        return :done if out2 == "200"
        [:blocked, "PAT itself appears invalid (HTTP #{out2} on /user)"]
      when "401", "403"
        [:blocked, "PAT lacks access to #{config.certs_slug} (HTTP #{out}). Check token scopes at github.com/settings/tokens"]
      else
        [:blocked, "Unexpected HTTP #{out} probing #{config.certs_slug}"]
      end
    end

    def do_it
      UI.fail!("GitHub credentials invalid. Fix #{config['GH_PAT_FILE']} or PAT scope, then re-run.")
    end
  end

  class RenameStub < Step
    def name; "Rename HelloApp → #{config['APP_NAME']}"; end

    def check
      # Done iff: shared swift file exists AND no leftover HelloApp / com.example.helloapp
      # references in source tree (excluding vendor, .git, .planning, build).
      shared = REPO_ROOT.join("app", "Shared", "#{config['APP_NAME']}.swift")
      shared.file? ? :done : :pending
    end

    def do_it
      args = [
        "bin/rename.sh",
        config["APP_NAME"], config["BUNDLE_ID"], config["DISPLAY_NAME"],
        "--email=#{config['APP_EMAIL']}",
        "--generator=#{config['GENERATOR']}",
        "--platforms=#{config.platforms.join(',')}"
      ]
      Sh.run!(*args)
      Sh.run!("bin/verify-rename.sh")
    end
  end

  class EditMatchfile < Step
    MODES = %w[ci].freeze
    def name; "Wire fastlane/Matchfile to certs repo"; end

    def matchfile; REPO_ROOT.join("fastlane", "Matchfile"); end

    def check
      return :pending unless matchfile.file?
      content = matchfile.read
      return :pending if content.include?("CHANGE-ME-ORG/CHANGE-ME-REPO-certs.git")
      content.include?(config.certs_slug) ? :done : :pending
    end

    def do_it
      content = matchfile.read
      content = content.gsub(
        %r{git_url\("https://github\.com/[^/]+/[^/]+\.git"\)},
        %{git_url("#{config.certs_url}")}
      )
      matchfile.write(content)
    end
  end

  class BrewBootstrap < Step
    def name; "Toolchain (brew + bundler + xcodegen/tuist + lefthook)"; end

    def check
      return :pending unless Sh.ok?("bundle", "check")
      tool = config["GENERATOR"] == "tuist" ? "tuist" : "xcodegen"
      Sh.ok?("which", tool) && Sh.ok?("which", "lefthook") ? :done : :pending
    end

    def do_it
      Sh.run!("make", "bootstrap")
    end
  end

  class InitialPush < Step
    def name; "Initial commit + push"; end

    def check
      out, ok = Sh.run("git", "ls-remote", "--heads", "origin", "main")
      return :pending unless ok && !out.strip.empty?
      # main exists on origin. Has rename landed?
      out2, _ = Sh.run("git", "diff", "--stat", "origin/main", "--", "app/Shared")
      out2.strip.empty? ? :done : :pending
    end

    def do_it
      _out, dirty = Sh.run("git", "diff", "--quiet")
      Sh.run!("git", "add", "-A") unless dirty
      Sh.run!("git", "-c", "user.email=#{config['APP_EMAIL']}", "-c", "user.name=#{config['APP_NAME']} bootstrap",
              "commit", "-m", "Bootstrap fork: rename + wire Matchfile") unless dirty
      Sh.run!("git", "push", "-u", "origin", "main")
    end
  end

  class BranchProtection < Step
    def name; "GitHub branch protection on main"; end

    def check
      # Probe for the protection's enforce_admins value. Two reasons to
      # re-run setup-github.sh (return :pending):
      #   1. No protection at all (HTTP 404) — first-time fork, hasn't run yet.
      #   2. Protection exists but enforce_admins doesn't match the current
      #      RELEASE_MODE. Lets a forker switch ci ↔ local later by editing
      #      .bootstrap.env + re-running `make bootstrap-fork`; without this
      #      drift detection, BranchProtection would stay :done and the
      #      protection config would silently mismatch the mode.
      out, ok = Sh.run("gh", "api",
                       "repos/#{config.repo_slug}/branches/main/protection",
                       "--jq", ".enforce_admins.enabled")
      return :pending unless ok
      current = out.strip == "true"
      desired = config.ci_mode?
      current == desired ? :done : :pending
    end

    def do_it
      Sh.run!("bin/setup-github.sh")
    end
  end

  class GHSecrets < Step
    MODES = %w[ci].freeze
    def name; "Set 7 GH Secrets on app repo"; end

    def check
      out, ok = Sh.run("gh", "secret", "list", "--repo", config.repo_slug)
      return :pending unless ok
      present = out.lines.map { |l| l.split(/\s+/).first }.compact
      REQUIRED_SECRETS.all? { |s| present.include?(s) } ? :done : :pending
    end

    def do_it
      # Generate or load match + keychain passwords.
      match_pw    = ensure_random_password("MATCH_PASSWORD_FILE", 32)
      keychain_pw = ensure_random_password("KEYCHAIN_PASSWORD_FILE", 32)
      pat         = config.expand_path("GH_PAT_FILE").read.strip
      gh_user     = github_user
      basic       = Base64.strict_encode64("#{gh_user}:#{pat}")

      p8 = config.expand_path("ASC_API_KEY_P8_PATH").read
      p8_base64 = Base64.strict_encode64(p8)

      values = {
        "MATCH_PASSWORD"                => match_pw,
        "MATCH_GIT_BASIC_AUTHORIZATION" => basic,
        "KEYCHAIN_PASSWORD"             => keychain_pw,
        "ASC_API_KEY_ID"                => config["ASC_API_KEY_ID"],
        "ASC_API_KEY_ISSUER_ID"         => config["ASC_API_KEY_ISSUER_ID"],
        "ASC_API_KEY_P8_BASE64"         => p8_base64,
        "FASTLANE_TEAM_ID"              => config["FASTLANE_TEAM_ID"]
      }

      values.each do |key, val|
        IO.popen(["gh", "secret", "set", key, "--repo", config.repo_slug], "w") { |io| io.write(val) }
        UI.fail!("gh secret set #{key} failed") unless $?.success?
      end
    end

    private

    def github_user
      out = Sh.run!("gh", "api", "/user", "-q", ".login").strip
      out
    end

    def ensure_random_password(env_key, length)
      path = config.expand_path(env_key)
      UI.fail!("#{env_key} not set in .bootstrap.env") unless path
      if path.file? && !path.read.strip.empty?
        return path.read.strip
      end
      FileUtils.mkdir_p(path.dirname)
      pw = SecureRandom.base64(length).gsub(/[^A-Za-z0-9]/, "")[0, length]
      path.write(pw)
      File.chmod(0o600, path.to_s)
      pw
    end
  end

  class CreateCertsRepo < Step
    MODES = %w[ci].freeze
    def name; "Private certs repo"; end

    def check
      Sh.ok?("gh", "repo", "view", config.certs_slug) ? :done : :pending
    end

    def do_it
      Sh.run!("gh", "repo", "create", config.certs_slug, "--private",
              "--description", "Encrypted certs + profiles for #{config.repo_slug} (managed via fastlane match)")
    end
  end

  class RegisterAppId < Step
    def name; "Register Bundle ID in Apple Developer Portal"; end

    def check
      require "spaceship"
      Bootstrap.ensure_asc_token!(config)
      Spaceship::ConnectAPI::BundleId.find(config["BUNDLE_ID"]) ? :done : :pending
    rescue StandardError => e
      [:blocked, "ASC probe failed: #{e.message}"]
    end

    def do_it
      env = asc_env(config)
      Sh.run!("bundle", "exec", "fastlane", "register_app_id", env: env)
    end
  end

  class VerifyAscApp < Step
    def name; "Verify ASC App record exists"; end
    def category; "human-gated"; end

    def check
      require "spaceship"
      Bootstrap.ensure_asc_token!(config)
      Spaceship::ConnectAPI::App.find(config["BUNDLE_ID"]) ? :done : [:blocked, asc_creation_msg]
    rescue StandardError => e
      [:blocked, "ASC probe failed: #{e.message}"]
    end

    def do_it
      UI.fail!(asc_creation_msg)
    end

    private

    # Human-readable label of the active platforms — for display in the
    # ASC creation hint. Mirrors bin/rename.sh's PLATFORMS_LABEL.
    def platforms_label
      ios   = config.ios?
      macos = config.macos?
      return "iOS + macOS" if ios && macos
      return "iOS"         if ios
      return "macOS"       if macos
      "iOS + macOS"  # defensive: shouldn't happen given Config.validate_platforms!
    end
    def asc_creation_msg
      <<~MSG
        ASC App record for #{config['BUNDLE_ID']} not found.

        The App Store Connect API does not allow POST /apps. Create the App
        record once via the web UI:

          1. Open https://appstoreconnect.apple.com/apps  →  + (New App)
          2. Platforms:        #{platforms_label}
             Name:             #{config['ASC_APP_NAME'].to_s.empty? ? config['DISPLAY_NAME'] : config['ASC_APP_NAME']}
             Primary Language: English (U.S.)
             Bundle ID:        #{config['BUNDLE_ID']}
             SKU:              #{config['ASC_APP_SKU'].to_s.empty? ? '(any unique string)' : config['ASC_APP_SKU']}
             User Access:      Full Access
          3. Re-run `make bootstrap` — this step will pass.
      MSG
    end
  end

  class BootstrapCerts < Step
    MODES = %w[ci].freeze
    def name
      bits = []
      bits << "iOS dist + dev" if config.ios?
      bits << "macOS dist"     if config.macos?
      "Mint #{bits.join(' + ')} certs (via match)"
    end

    def check
      tree = certs_tree
      return :pending if tree.empty?
      has_dist  = tree.any? { |p| p.start_with?("certs/distribution/") && p.end_with?(".cer") }
      has_dev   = tree.any? { |p| p.start_with?("certs/development/") && p.end_with?(".cer") }
      # Apple Distribution + Apple Development certs are required regardless of
      # platforms — both iOS and macOS distribution signing rely on them.
      return :pending unless has_dist && has_dev
      # Provisioning profiles are platform-specific. Only require those for the
      # platforms the fork actually ships.
      if config.ios?
        has_ios  = tree.any? { |p| p.match?(%r{^profiles/appstore/.*\.mobileprovision$}) }
        has_devp = tree.any? { |p| p.match?(%r{^profiles/development/.*\.mobileprovision$}) }
        return :pending unless has_ios && has_devp
      end
      if config.macos?
        has_macos = tree.any? { |p| p.match?(%r{^profiles/appstore/.*\.provisionprofile$}) }
        return :pending unless has_macos
      end
      :done
    end

    def do_it
      env = Bootstrap.asc_env(config).merge(Bootstrap.match_env(config))
      out, ok = Sh.run("bundle", "exec", "fastlane", "bootstrap_certs", env: env)
      return if ok
      hint = Bootstrap.match_failure_hint(out)
      UI.fail!(<<~MSG)
        bootstrap_certs lane failed.
        #{hint ? "Likely cause: #{hint}" : "See full output above."}
      MSG
    end

    private

    def certs_tree
      out, ok = Sh.run("gh", "api", "repos/#{config.certs_slug}/git/trees/master?recursive=true",
                       "--jq", ".tree[].path")
      ok ? out.lines.map(&:strip) : []
    end
  end

  class MintInstaller < Step
    MODES = %w[ci].freeze
    PLATFORMS = %w[macos].freeze
    def name; "Mint Mac Installer Distribution cert"; end

    def check
      out, ok = Sh.run("gh", "api", "repos/#{config.certs_slug}/git/trees/master?recursive=true",
                       "--jq", ".tree[].path")
      return :pending unless ok
      out.lines.any? { |p| p.start_with?("certs/mac_installer_distribution/") && p.end_with?(".cer\n") } ? :done : :pending
    end

    def do_it
      env = Bootstrap.asc_env(config).merge(Bootstrap.match_env(config))
      out, ok = Sh.run("bundle", "exec", "ruby", "bin/mint-installer-cert.rb", env: env)
      unless ok
        hint = Bootstrap.match_failure_hint(out)
        UI.fail!("mint-installer-cert.rb failed.\n#{hint ? "Likely cause: #{hint}" : ''}")
      end
      cert_id = out.lines.grep(/^Cert id:/).first&.split(":", 2)&.last&.strip
      UI.fail!("could not parse INSTALLER_CERT_ID from mint-installer-cert.rb output") if cert_id.to_s.empty?
      env2 = env.merge("INSTALLER_CERT_ID" => cert_id)
      Sh.run!("bundle", "exec", "ruby", "bin/import-installer-to-match.rb", env: env2)
    end
  end

  class Icon1024 < Step
    def name; "Replace 1024 icon"; end

    def icon_target
      REPO_ROOT.join("app", "iOS", "Assets.xcassets", "AppIcon.appiconset", "Icon-1024.png")
    end

    def check
      unless config.set?("ICON_1024_PATH")
        return [:warn, "ICON_1024_PATH unset; the template hammer icon will ship. Required for App Store review (not TestFlight)."]
      end
      src = config.expand_path("ICON_1024_PATH")
      return [:blocked, "ICON_1024_PATH does not exist: #{src}"] unless src.file?
      return :pending unless icon_target.file?
      Digest::SHA256.file(src).hexdigest == Digest::SHA256.file(icon_target).hexdigest ? :done : :pending
    end

    def do_it
      src = config.expand_path("ICON_1024_PATH")
      FileUtils.cp(src, icon_target)
    end
  end

  class MakeIcons < Step
    PLATFORMS = %w[macos].freeze
    def name; "Regenerate macOS icon set + .icns"; end

    def check
      return :done unless config.set?("ICON_1024_PATH") # optional gate
      icns = REPO_ROOT.join("app", "macOS", "Assets.xcassets", "AppIcon.appiconset", "icon_512x512@2x.png")
      icons_target_mtime = icns.file? ? icns.mtime : Time.at(0)
      icon_src = REPO_ROOT.join("app", "iOS", "Assets.xcassets", "AppIcon.appiconset", "Icon-1024.png")
      icons_target_mtime >= icon_src.mtime ? :done : :pending
    end

    def do_it
      Sh.run!("make", "icons")
    end
  end

  class ScanMetadata < Step
    def name; "App Store metadata text files"; end

    def metadata_dir; REPO_ROOT.join("fastlane", "metadata", "en-US"); end
    def review_dir;   REPO_ROOT.join("fastlane", "metadata", "review_information"); end

    def check
      todos = []
      [metadata_dir, review_dir].each do |dir|
        next unless dir.directory?
        Dir.glob(dir.join("*.txt")).each do |f|
          content = File.read(f)
          if content.match?(/\bTODO\b|REPLACE_ME|com\.example\.helloapp|HelloApp/i)
            todos << Pathname.new(f).relative_path_from(REPO_ROOT).to_s
          elsif content.strip.empty?
            todos << "#{Pathname.new(f).relative_path_from(REPO_ROOT)} (empty)"
          end
        end
      end
      return :done if todos.empty?
      [:warn, "#{todos.length} files need attention before App Store review:\n  - #{todos.join("\n  - ")}"]
    end

    def do_it
      # No-op; check returns :warn or :done, never :pending.
    end
  end

  class ScanScreenshots < Step
    def name; "App Store screenshots"; end

    def screenshot_dir; REPO_ROOT.join("fastlane", "screenshots", "en-US"); end

    def check
      return [:warn, "No fastlane/screenshots/en-US/ — capture via `ci/take-screenshots.sh` before App Store review (not TestFlight)."] unless screenshot_dir.directory?
      pngs = Dir.glob(screenshot_dir.join("*.png"))
      return [:warn, "No screenshots in #{screenshot_dir.relative_path_from(REPO_ROOT)} — capture via `ci/take-screenshots.sh` before App Store review."] if pngs.empty?
      :done
    end

    def do_it
      # No-op; check returns :warn or :done.
    end
  end

  class RemoteMatches < Step
    def name; "GH_APP_REPO matches origin git remote"; end
    def category; "preflight"; end

    def check
      out, ok = Sh.run("git", "remote", "get-url", "origin")
      return [:warn, "no origin remote yet (initial push hasn't happened — that's fine)"] unless ok
      url = out.strip
      expected = "https://github.com/#{config.repo_slug}.git"
      expected_ssh = "git@github.com:#{config.repo_slug}.git"
      return :done if url == expected || url == expected_ssh
      [:blocked, <<~MSG]
        .bootstrap.env GH_APP_REPO=#{config['GH_APP_REPO']} (#{config.repo_slug})
        but git remote points at: #{url}

        Fix one or the other:
          - update GH_ORG/GH_APP_REPO in .bootstrap.env, or
          - run: git remote set-url origin #{expected}
      MSG
    end

    def do_it
      UI.fail!("git remote and .bootstrap.env GH_APP_REPO disagree; fix manually.")
    end
  end

  class LocalKeychainCerts < Step
    MODES = %w[local].freeze
    def name; "Local keychain has signing identities"; end

    # Required by all forks regardless of platforms — Apple Distribution is the
    # signing identity for both iOS .ipa and macOS .pkg/.app archives, and
    # Apple Development covers device + Mac development signing.
    REQUIRED_IDENTITIES_ALWAYS = [
      "Apple Distribution",
      "Apple Development"
    ].freeze

    # Required only when shipping macOS — used by productbuild to sign the
    # .pkg installer wrapper.
    REQUIRED_IDENTITIES_MACOS = [
      "3rd Party Mac Developer Installer"
    ].freeze

    # Maps the human identity name (as it appears in `security find-identity`)
    # to fastlane cert's --type argument. Auto-mint flow uses these to invoke
    # the right fastlane cert call per missing identity.
    IDENTITY_TO_CERT_TYPE = {
      "Apple Distribution"                => "apple_distribution",
      "Apple Development"                 => "apple_development",
      "3rd Party Mac Developer Installer" => "mac_installer_distribution"
    }.freeze

    def required_identities
      ids = REQUIRED_IDENTITIES_ALWAYS.dup
      ids.concat(REQUIRED_IDENTITIES_MACOS) if config.macos?
      ids
    end

    # Returns the matching `security find-identity -v` lines from the user's
    # login keychain. Each line is e.g.
    #   '  1) BD06...A78 "Apple Distribution: Person Name (A26TJZ8QHQ)"'
    #
    # Note we deliberately do NOT pass `-p codesigning` here, because that
    # filter excludes installer-signing identities (3rd Party Mac Developer
    # Installer is for `productbuild`, not for code signing). Without -p,
    # find-identity returns valid identities for ANY policy — code-signing,
    # installer-signing, mail-signing, etc. -v alone keeps the validity
    # check (filters out expired or private-key-missing identities). We
    # match by name in the caller, so policy mixing here is fine.
    def keychain_lines
      out, _ok = Sh.run("security", "find-identity", "-v",
                        File.expand_path("~/Library/Keychains/login.keychain-db"))
      out.lines
    end

    # Pulls the LAST `(XXXXXXXXXX)` 10-char alphanumeric token from an
    # identity line. For
    #   '  1) BD06...A78 "Apple Distribution: Person Name (A26TJZ8QHQ)"'
    # returns "A26TJZ8QHQ". We use scan-and-pick-last because the line ends
    # in `"` (not `)`), so a `\)\s*$`-anchored pattern wouldn't fire.
    #
    # Caveat: Apple's "Created via API" cert names use the same `(XXXXXXXXXX)`
    # shape but the token is the API key id, NOT the team id. We can't tell
    # the two apart from `find-identity` output alone — that's why
    # team_mismatched_identities is permissive on lines containing
    # "Created via API".
    def extract_team_id(line)
      line.scan(/\(([A-Z0-9]{10})\)/).last&.first
    end

    # Identities whose name doesn't appear at all in the keychain. These
    # require fresh minting (or manual install).
    def missing_identities
      lines = keychain_lines
      required_identities.reject do |name|
        lines.any? { |line| line.include?(name) }
      end
    end

    # Identities present BUT whose certs are all clearly for non-matching
    # teams. Conservative logic — only flagged when:
    #   1. At least one cert with the right name exists (else: missing, not mismatched)
    #   2. None of those certs has a parenthesized team id matching FASTLANE_TEAM_ID
    #   3. None is "Created via API" (ambiguous — we can't verify the team)
    # Catches the consultant / multi-team scenario without false-positiving on
    # API-minted certs that may be for the right team.
    def team_mismatched_identities
      expected = config["FASTLANE_TEAM_ID"]
      return [] if expected.nil? || expected.empty?

      lines = keychain_lines
      required_identities.select do |name|
        type_lines = lines.select { |line| line.include?(name) }
        next false if type_lines.empty?               # missing, not mismatched
        next false if type_lines.any? { |line| extract_team_id(line) == expected }
        next false if type_lines.any? { |line| line.include?("Created via API") }
        true
      end
    end

    def check
      return :done if config.ci_mode?
      missing = missing_identities
      mismatched = team_mismatched_identities
      return :done if missing.empty? && mismatched.empty?
      # :pending (with rich message) — bootstrap-fork's do_it auto-mints
      # the missing/mismatched identities via fastlane cert. Doctor renders
      # the message so the user knows what's going to happen and can opt
      # for one of the manual paths if they prefer.
      [:pending, build_message(missing, mismatched)]
    end

    # do_it (called by `make bootstrap-fork` and `make mint-local-certs`)
    # auto-mints any missing OR mismatched-team identities by shelling out to
    # the fastlane mint_local_certs lane. Idempotent — fastlane cert itself
    # detects existing valid certs and skips minting duplicates, so re-running
    # is safe even if the keychain state changed since `make doctor` ran.
    def do_it
      needed = (missing_identities + team_mismatched_identities).uniq
      return if needed.empty?

      cert_types = needed.map { |id| IDENTITY_TO_CERT_TYPE.fetch(id) }
      UI.section "Minting #{needed.length} local-mode signing identit#{needed.length == 1 ? 'y' : 'ies'}"
      needed.each_with_index do |id, i|
        puts "  #{i + 1}. #{id}  (fastlane cert --type #{cert_types[i]})"
      end

      env = Bootstrap.asc_env(config)
      Sh.run!("bundle", "exec", "fastlane", "mint_local_certs",
              "types:#{cert_types.join(',')}",
              env: env)
    end

    private

    def build_message(missing, mismatched)
      parts = []

      if missing.any?
        parts << "Login keychain is missing #{missing.length} signing identit#{missing.length == 1 ? 'y' : 'ies'}:"
        missing.each do |id|
          parts << "  - #{id}  (fastlane cert --type #{IDENTITY_TO_CERT_TYPE.fetch(id)})"
        end
      end

      if mismatched.any?
        parts << "" if missing.any?
        expected = config["FASTLANE_TEAM_ID"]
        parts << "Found certs for #{mismatched.length} identit#{mismatched.length == 1 ? 'y' : 'ies'} but none for team #{expected}:"
        mismatched.each { |id| parts << "  - #{id}" }
        parts << "(your keychain has certs from other teams. xcodebuild will fail at"
        parts << " ship time without a team-#{expected} cert.)"
      end

      parts << ""
      parts << "Easiest fix — auto-mints + installs each identity into your login keychain:"
      parts << "  make mint-local-certs"
      parts << ""
      parts << "(or just run `make bootstrap-fork`; it auto-mints these too.)"
      parts << ""
      parts << "Manual alternatives:"
      parts << "  Xcode → Settings → Accounts → (your team) → Manage Certificates → +"
      parts << "  Apple Developer Portal → Certificates → + (then double-click the .cer)"

      # macOS-only escape hatch: if every problem is a Mac-only identity, the
      # user can drop macOS shipping by setting PLATFORMS=ios — saves them
      # from minting a cert they don't need.
      affected = (missing + mismatched).uniq
      mac_only = affected.all? { |id| REQUIRED_IDENTITIES_MACOS.include?(id) } && affected.any?
      if mac_only
        parts << ""
        parts << "Or, if you don't need to ship macOS yet:"
        parts << "  set PLATFORMS=ios in .bootstrap.env (skips Mac signing entirely)"
      end

      parts.join("\n") + "\n"
    end
  end

  # ─── Pipeline ───────────────────────────────────────────────────────────────

  class Runner
    # Single source of truth. Each Step subclass sets MODES = %w[ci]
    # / %w[local] / both (default). Runner filters at construction time.
    PIPELINE = [
      CheckAppleCreds,
      CheckGHCreds,
      RemoteMatches,
      RenameStub,
      EditMatchfile,        # ci-only
      BrewBootstrap,
      Icon1024,              # tree mutations land before InitialPush
      MakeIcons,
      InitialPush,
      BranchProtection,
      CreateCertsRepo,       # ci-only
      GHSecrets,             # ci-only
      RegisterAppId,
      VerifyAscApp,
      BootstrapCerts,        # ci-only
      MintInstaller,         # ci-only
      LocalKeychainCerts,    # local-only
      ScanMetadata,          # informational
      ScanScreenshots
    ].freeze

    def initialize(config)
      @config = config
      mode = config.release_mode
      @steps = PIPELINE
        .map { |klass| klass.new(config) }
        .select { |step| step.applicable?(mode, config.platforms) }
    end

    def doctor
      @config.validate!
      UI.section "Configuration"
      puts "  app:     #{@config['APP_NAME']} (#{@config['BUNDLE_ID']})"
      puts "  mode:    RELEASE_MODE=#{UI.bold @config.release_mode}"
      puts "  apple:   team #{@config['FASTLANE_TEAM_ID']}, ASC key #{@config['ASC_API_KEY_ID']}"
      gh_line = "  gh:      app=#{@config.repo_slug}"
      gh_line += " certs=#{@config.certs_slug}" if @config.ci_mode?
      puts gh_line

      UI.section "Pipeline status"
      results = []
      blockers = []  # collected for the action-required tail message
      @steps.each_with_index do |step, idx|
        result = step.check
        case result
        when :done
          puts "  #{(idx + 1).to_s.rjust(2)}. #{UI.ok step.name}"
          results << :done
        when :pending
          puts "  #{(idx + 1).to_s.rjust(2)}. #{UI.miss step.name}#{UI.dim ' — will run on bootstrap-fork'}"
          results << :pending
        when Array
          severity, msg = result
          if severity == :warn
            puts "  #{(idx + 1).to_s.rjust(2)}. #{UI.warn step.name}"
            puts msg.lines.map { |l| "      #{UI.dim l.chomp}" }.join("\n")
            results << :warn
          elsif severity == :pending
            # Pending-with-message: doctor explains the fix; bootstrap-fork's
            # do_it auto-runs and resolves it. Rendered like :pending (red ✗
            # + dim "will auto-fix on bootstrap-fork") plus the rich message
            # so the user can ALSO fix it manually if they want
            # (e.g. `make mint-local-certs`, `PLATFORMS=ios` escape hatch, etc).
            puts "  #{(idx + 1).to_s.rjust(2)}. #{UI.miss step.name}#{UI.dim ' — will auto-fix on bootstrap-fork'}"
            puts msg.lines.map { |l| "      #{UI.dim l.chomp}" }.join("\n")
            results << :pending
          else
            # Blocked: visually separate from :warn (advisory) by using the
            # red ✗ glyph + a "needs fix" suffix, and from :pending by
            # rendering the underlying error message at full intensity
            # (not dim) so it pulls the eye.
            puts "  #{(idx + 1).to_s.rjust(2)}. #{UI.miss step.name}#{UI.bold ' — needs fix'}"
            puts msg.lines.map { |l| "      #{l}" }.join
            results << :blocked
            blockers << "#{idx + 1}. #{step.name}"
          end
        end
      end

      UI.section "Summary"
      done    = results.count(:done)
      pending = results.count(:pending)
      blocked = results.count(:blocked)
      warned  = results.count(:warn)
      cells = ["#{UI.ok "#{done} done"}"]
      cells << UI.miss("#{pending} pending") if pending > 0
      cells << UI.warn("#{warned} advisory") if warned > 0
      cells << UI.miss("#{blocked} blocked") if blocked > 0
      puts "  #{cells.join('    ')}"

      if blocked > 0
        puts
        puts UI.bold "Action required: fix the ✗ blocked items above, then re-run `make doctor`:"
        blockers.each { |b| puts UI.dim("  • #{b}") }
        if warned > 0
          puts
          puts UI.dim("(#{warned} advisory ⚠ items above are App-Store-review-only and don't block TestFlight.)")
        end
        exit 2
      elsif pending > 0
        puts
        puts UI.bold "Run `make bootstrap-fork` to close the ✗ pending items, or `make all` for the full forker journey (bootstrap-fork → ship → verify)."
        puts UI.dim("(#{warned} advisory ⚠ items above are App-Store-review-only and don't block TestFlight.)") if warned > 0
        exit 0
      else
        puts
        puts UI.bold "All bootstrap steps complete. Run `make ship` to trigger a release."
        puts UI.dim("(#{warned} advisory ⚠ items above are App-Store-review-only and don't block TestFlight.)") if warned > 0
        exit 0
      end
    end

    def bootstrap
      @config.validate!
      total = @steps.length
      @steps.each_with_index do |step, idx|
        UI.step_header(idx + 1, total, step.name)
        result = step.check
        case result
        when :done
          puts "  #{UI.ok 'already done'}"
        when :pending
          step.do_it
          puts "  #{UI.ok 'done'}"
        when Array
          severity, msg = result
          if severity == :warn
            puts "  #{UI.warn msg.lines.first.chomp}"
          elsif severity == :pending
            # Auto-fixable: bootstrap-fork runs do_it (which mints/restores
            # state programmatically). Distinct from :blocked which is
            # human-gated and aborts.
            step.do_it
            puts "  #{UI.ok 'done'}"
          else
            UI.fail!(msg)
          end
        end
      end
      puts
      puts UI.bold "✅ Bootstrap complete."
      puts "Next: #{UI.bold 'make ship'} to trigger the release pipeline."
    end
  end

  # ─── Module-level helpers used by multiple steps ────────────────────────────

  module_function

  def Bootstrap.ensure_asc_token!(config)
    return if Spaceship::ConnectAPI.token
    p8_path = config.expand_path("ASC_API_KEY_P8_PATH")
    Spaceship::ConnectAPI.token = Spaceship::ConnectAPI::Token.create(
      key_id:    config["ASC_API_KEY_ID"],
      issuer_id: config["ASC_API_KEY_ISSUER_ID"],
      filepath:  p8_path.to_s
    )
  end

  def self.match_failure_hint(output)
    case output
    when /Could not create another (Distribution|Development) certificate, reached the maximum/i
      "Apple cert quota exhausted (3/team for Distribution). Find an unused cert via\n" \
      "  bundle exec fastlane list_certs\n" \
      "and revoke it via\n" \
      "  bundle exec fastlane revoke_cert id:<CERT_ID>\n" \
      "then re-run `make bootstrap-fork`."
    when /Could not find the newly generated certificate installed/i
      "fastlane match's keychain verification quirk on populated login keychains.\n" \
      "See docs/CONTINUOUS-VALIDATION.md G11 + the workaround uses CERT_KEYCHAIN_PATH (set automatically by Bootstrap.match_env)."
    when /Authentication credentials are missing or invalid/i
      "ASC API key was rejected. Verify ASC_API_KEY_ID + ASC_API_KEY_ISSUER_ID match\n" \
      "the .p8 in ASC_API_KEY_P8_PATH. ASC keys can be revoked at\n" \
      "  https://appstoreconnect.apple.com/access/api"
    when /Error cloning certificates git repo/i
      "fastlane match couldn't access #{config_or_unknown(output, 'GH_CERTS_REPO')}.\n" \
      "Check that MATCH_GIT_BASIC_AUTHORIZATION's PAT has access (G12 in CONTINUOUS-VALIDATION.md)."
    end
  end

  def self.config_or_unknown(_output, _key)
    "the certs repo"
  end

  def asc_env(config)
    {
      "ASC_API_KEY_ID"          => config["ASC_API_KEY_ID"],
      "ASC_API_KEY_ISSUER_ID"   => config["ASC_API_KEY_ISSUER_ID"],
      "ASC_API_KEY_P8_BASE64"   => Base64.strict_encode64(config.expand_path("ASC_API_KEY_P8_PATH").read),
      "FASTLANE_TEAM_ID"        => config["FASTLANE_TEAM_ID"],
      # The release lane in fastlane/Fastfile reads RELEASE_MODE to decide
      # whether to run match (ci-mode certs from the private certs repo) vs
      # skip match and use the user's login keychain (local-mode signing).
      # Without this propagation, local-mode forks hit the unedited
      # CHANGE-ME-ORG/CHANGE-ME-REPO-certs.git Matchfile placeholder and
      # match aborts cloning a 404 URL.
      "RELEASE_MODE"            => config.release_mode,
      "FASTLANE_HIDE_CHANGELOG" => "1",
      "FASTLANE_SKIP_UPDATE_CHECK" => "1"
    }
  end

  def match_env(config)
    pat   = config.expand_path("GH_PAT_FILE").read.strip
    user  = `gh api /user -q .login`.strip
    {
      "MATCH_PASSWORD"                => config.expand_path("MATCH_PASSWORD_FILE").read.strip,
      "MATCH_GIT_BASIC_AUTHORIZATION" => Base64.strict_encode64("#{user}:#{pat}"),
      "KEYCHAIN_PASSWORD"             => config.expand_path("KEYCHAIN_PASSWORD_FILE").read.strip,
      "CERT_KEYCHAIN_PATH"            => Pathname.new(Dir.home).join("Library", "Keychains", "match-tmp.keychain-db").to_s
    }
  end
end
