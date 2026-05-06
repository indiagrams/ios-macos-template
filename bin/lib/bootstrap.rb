# frozen_string_literal: true

# Shared library for `bin/doctor.rb` (read-only) and `bin/bootstrap-fork.rb`
# (idempotent driver). Reads `.bootstrap.env`, validates config, exposes a
# pipeline of 14 steps. Each step has a `check` (returns bool, no side effects)
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
    REQUIRED = %w[
      APP_NAME BUNDLE_ID DISPLAY_NAME APP_EMAIL GENERATOR
      FASTLANE_TEAM_ID ASC_API_KEY_ID ASC_API_KEY_ISSUER_ID ASC_API_KEY_P8_PATH
      GH_ORG GH_APP_REPO GH_CERTS_REPO GH_PAT_FILE
      MATCH_PASSWORD_FILE KEYCHAIN_PASSWORD_FILE
    ].freeze

    OPTIONAL = %w[ICON_1024_PATH ASC_APP_SKU ASC_APP_NAME].freeze

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
        # Strip surrounding quotes if symmetric
        val = val.strip
        if (val.start_with?("'") && val.end_with?("'")) || (val.start_with?('"') && val.end_with?('"'))
          val = val[1..-2]
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
      missing = REQUIRED.reject { |k| set?(k) }
      return if missing.empty?
      UI.fail!(<<~MSG)
        .bootstrap.env is missing required fields:
        #{missing.map { |k| "  - #{k}" }.join("\n")}

        Edit .bootstrap.env and re-run.
      MSG
    end

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
    attr_reader :config

    def initialize(config)
      @config = config
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
      pat_file = config.expand_path("GH_PAT_FILE")
      return [:blocked, "GH_PAT_FILE doesn't exist: #{pat_file}"] unless pat_file && pat_file.file?
      pat = pat_file.read.strip
      return [:blocked, "GH_PAT_FILE is empty"] if pat.empty?

      # Probe certs repo via PAT
      out, success = Sh.run("curl", "-s", "-o", "/dev/null", "-w", "%{http_code}",
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
        "--generator=#{config['GENERATOR']}"
      ]
      Sh.run!(*args)
      Sh.run!("bin/verify-rename.sh")
    end
  end

  class EditMatchfile < Step
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
      Sh.ok?("gh", "api", "repos/#{config.repo_slug}/branches/main/protection") ? :done : :pending
    end

    def do_it
      Sh.run!("bin/setup-github.sh")
    end
  end

  class GHSecrets < Step
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

    def asc_creation_msg
      <<~MSG
        ASC App record for #{config['BUNDLE_ID']} not found.

        The App Store Connect API does not allow POST /apps. Create the App
        record once via the web UI:

          1. Open https://appstoreconnect.apple.com/apps  →  + (New App)
          2. Platforms:        iOS + macOS
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
    def name; "Mint iOS dist + dev + macOS dist certs (via match)"; end

    def check
      tree = certs_tree
      return :pending if tree.empty?
      has_dist  = tree.any? { |p| p.start_with?("certs/distribution/") && p.end_with?(".cer") }
      has_dev   = tree.any? { |p| p.start_with?("certs/development/") && p.end_with?(".cer") }
      has_ios   = tree.any? { |p| p.match?(%r{^profiles/appstore/.*\.mobileprovision$}) }
      has_macos = tree.any? { |p| p.match?(%r{^profiles/appstore/.*\.provisionprofile$}) }
      has_devp  = tree.any? { |p| p.match?(%r{^profiles/development/.*\.mobileprovision$}) }
      (has_dist && has_dev && has_ios && has_macos && has_devp) ? :done : :pending
    end

    def do_it
      env = asc_env(config).merge(match_env(config))
      Sh.run!("bundle", "exec", "fastlane", "bootstrap_certs", env: env)
    end

    private

    def certs_tree
      out, ok = Sh.run("gh", "api", "repos/#{config.certs_slug}/git/trees/master?recursive=true",
                       "--jq", ".tree[].path")
      ok ? out.lines.map(&:strip) : []
    end
  end

  class MintInstaller < Step
    def name; "Mint Mac Installer Distribution cert"; end

    def check
      out, ok = Sh.run("gh", "api", "repos/#{config.certs_slug}/git/trees/master?recursive=true",
                       "--jq", ".tree[].path")
      return :pending unless ok
      out.lines.any? { |p| p.start_with?("certs/mac_installer_distribution/") && p.end_with?(".cer\n") } ? :done : :pending
    end

    def do_it
      env = asc_env(config).merge(match_env(config))
      out = Sh.run!("bundle", "exec", "ruby", "bin/mint-installer-cert.rb", env: env)
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
      return :done unless config.set?("ICON_1024_PATH") # optional
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

  # ─── Pipeline ───────────────────────────────────────────────────────────────

  class Runner
    PIPELINE = [
      CheckAppleCreds,
      CheckGHCreds,
      RenameStub,
      EditMatchfile,
      BrewBootstrap,
      InitialPush,
      BranchProtection,
      CreateCertsRepo,
      GHSecrets,
      RegisterAppId,
      VerifyAscApp,
      BootstrapCerts,
      MintInstaller,
      Icon1024,
      MakeIcons
    ].freeze

    def initialize(config)
      @config = config
      @steps = PIPELINE.map { |klass| klass.new(config) }
    end

    def doctor
      @config.validate!
      UI.section "Configuration"
      puts "  app:    #{@config['APP_NAME']} (#{@config['BUNDLE_ID']})"
      puts "  apple:  team #{@config['FASTLANE_TEAM_ID']}, ASC key #{@config['ASC_API_KEY_ID']}"
      puts "  gh:     app=#{@config.repo_slug} certs=#{@config.certs_slug}"

      UI.section "Pipeline status"
      results = []
      @steps.each_with_index do |step, idx|
        result = step.check
        case result
        when :done
          puts "  #{(idx + 1).to_s.rjust(2)}. #{UI.ok step.name}"
          results << :done
        when :pending
          puts "  #{(idx + 1).to_s.rjust(2)}. #{UI.miss step.name}#{UI.dim ' — will run on bootstrap'}"
          results << :pending
        when Array
          puts "  #{(idx + 1).to_s.rjust(2)}. #{UI.warn step.name}"
          puts result[1].lines.map { |l| "      #{l}" }.join
          results << :blocked
        end
      end

      UI.section "Summary"
      done    = results.count(:done)
      pending = results.count(:pending)
      blocked = results.count(:blocked)
      puts "  #{UI.ok "#{done} done"}    #{UI.miss "#{pending} pending"}    #{UI.warn "#{blocked} blocked"}"

      if blocked > 0
        puts
        puts UI.bold "Action required: resolve the ⚠ items above, then re-run `make doctor`."
        exit 2
      elsif pending > 0
        puts
        puts UI.bold "Run `make bootstrap` to close the ✗ items."
        exit 0
      else
        puts
        puts UI.bold "All steps complete. Run `make ship` to trigger a release."
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
          UI.fail!(result[1])
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

  def asc_env(config)
    {
      "ASC_API_KEY_ID"          => config["ASC_API_KEY_ID"],
      "ASC_API_KEY_ISSUER_ID"   => config["ASC_API_KEY_ISSUER_ID"],
      "ASC_API_KEY_P8_BASE64"   => Base64.strict_encode64(config.expand_path("ASC_API_KEY_P8_PATH").read),
      "FASTLANE_TEAM_ID"        => config["FASTLANE_TEAM_ID"],
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
