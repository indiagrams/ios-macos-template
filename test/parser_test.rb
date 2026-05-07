#!/usr/bin/env ruby
# frozen_string_literal: true

# Regression test for Bootstrap::Config.parse.
#
# Why this exists: a real first-time-shipper validation surfaced a parser bug
# (#108) where inline `# comments` were kept as part of values, corrupting
# every fillable field with comment text. The bug had been live for months
# without surfacing because the maintainer's own .bootstrap.env had no
# inline comments — only a naive first-timer would trip it.
#
# This test pins the parser's contract:
#   - Strip ` #` (space-hash) onward from unquoted values.
#   - Preserve `#` inside quoted values.
#   - Preserve bare `#` inside unquoted values (URL fragments etc.).
#   - Empty value followed by inline comment becomes the empty string.
#   - Both leading and trailing whitespace are stripped.
#
# Runnable locally:
#   bundle exec ruby test/parser_test.rb
#
# Wired into bootstrap-doctor-matrix.yml's `parser-regression` job.

$LOAD_PATH.unshift File.expand_path("../bin", __dir__)
require "lib/bootstrap"
require "tempfile"
require "pathname"

@failures = 0

def assert_eq(actual, expected, label)
  if actual == expected
    puts "  \u2713 #{label}"
  else
    puts "  \u2717 #{label}"
    puts "    expected: #{expected.inspect}"
    puts "    actual:   #{actual.inspect}"
    @failures += 1
  end
end

# Fixture mimics what `make init` scaffolds + a naive forker's typical edits:
# values placed in front of the existing inline `# placeholder` comments.
# This is the exact shape that broke before #108.
fixture = <<~ENV
  # ─── full-line comment, should be skipped ─────────────────────────────────
  APP_NAME=MyApp                          # CamelCase. Becomes scheme + product.
  BUNDLE_ID=com.foo.bar                   # iOS + macOS share the same bundle id.
  DISPLAY_NAME='My App With # In Quotes'  # quoted value with # inside; the
                                          # regex must NOT strip the inner #.
  WEB_URL=https://example.com/page#section   # URL fragment — preserve bare #.
  EMPTY_FIELD=                            # placeholder; should parse as ""
  PADDED=  value with spaces              # leading + trailing whitespace
  TABBED=value\tafter\ttab                # bare tab in unquoted value
  COMMENT_ONLY_TAB=value\t# tab-comment   # tab+hash IS a comment delimiter
  HASH_NO_SPACE=before#after              # bare # without preceding space
ENV

f = Tempfile.new(".bootstrap.env")
f.write(fixture)
f.close
config = Bootstrap::Config.parse(Pathname.new(f.path))
f.unlink

puts "Parser regression tests:"
assert_eq config["APP_NAME"],         "MyApp",                              "strips inline space-hash from unquoted alphanumeric value"
assert_eq config["BUNDLE_ID"],        "com.foo.bar",                        "strips inline space-hash from value containing dots"
assert_eq config["DISPLAY_NAME"],     "My App With # In Quotes",            "preserves # inside symmetrically-quoted value"
assert_eq config["WEB_URL"],          "https://example.com/page#section",   "preserves bare # in URL fragment, strips trailing comment"
assert_eq config["EMPTY_FIELD"],      "",                                   "empty-value-followed-by-comment becomes empty string"
assert_eq config["PADDED"],           "value with spaces",                  "strips both leading and trailing whitespace"
assert_eq config["TABBED"],           "value\tafter\ttab",                  "preserves bare tabs inside unquoted value (no following hash)"
assert_eq config["COMMENT_ONLY_TAB"], "value",                              "tab-hash is a valid comment delimiter (\\s matches tab)"
assert_eq config["HASH_NO_SPACE"],    "before#after",                       "preserves bare # without preceding whitespace"

if @failures.zero?
  puts "\nAll #{9} parser regression tests passed."
  exit 0
else
  puts "\n#{@failures} test(s) failed."
  exit 1
end
