require 'net/http'
require 'uri'
require 'json'
require 'fileutils'

# Base class for all linkyee plugins.
#
# A plugin is a Ruby class living under `./plugins/<ClassName>.rb` that is
# enabled via `config.yml`:
#
#   plugins:
#     - MyPlugin:
#         - some
#         - args
#
# At build time scaffold.rb instantiates `MyPlugin.new(<values from yaml>)`
# and calls `execute`. Whatever `execute` returns is stored under
# `vars.MyPlugin` and is then available inside `config.yml` and theme
# templates as `{{ vars.MyPlugin }}` (Liquid).
#
# ─── Subclass contract ────────────────────────────────────────────────
#
# Subclasses MUST:
#   - Inherit from Plugin (`class MyPlugin < Plugin`)
#   - Be saved as `./plugins/MyPlugin.rb` (filename == class name)
#   - Override `execute` and return a value Liquid can render
#     (String, Numeric, Hash with String keys, Array, or nested combos).
#
# Subclasses SHOULD:
#   - Use the helpers below (`http_get`, `http_get_json`, `log`, `cache`)
#     instead of reaching for Net::HTTP directly. They are battle-tested,
#     follow redirects, set a sensible User-Agent, and never raise.
#   - Be defensive: a flaky external API should NOT break the whole build.
#     If a fetch fails, return a safe default (0, "", {}, []).
#
# ─── Accessing arguments ──────────────────────────────────────────────
#
# linkyee passes plugin args from config.yml as `data` (array of values).
# For convenience use:
#
#   `args`   – the first argument list (typical case: a YAML list)
#   `params` – first argument when it is a Hash (typical case: keyword-style)
#
# Example (list-style):
#   plugins:
#     - GithubRepoStarsCountPlugin:
#         - ZhgChgLi/linkyee
#         - ZhgChgLi/ZMarkupParser
#   # inside the plugin: args == ["ZhgChgLi/linkyee", "ZhgChgLi/ZMarkupParser"]
#
# Example (hash-style):
#   plugins:
#     - RSSFeedPlugin:
#         url: https://blog.zhgchg.li/feed
#         limit: 5
#   # inside the plugin: params == {"url" => "...", "limit" => 5}
class Plugin
  attr_reader :data

  def initialize(data)
    @data = data
  end

  # Override in subclasses.
  def execute
  end

  # First positional argument list, e.g. `["repo1", "repo2"]`.
  # Returns [] if no arguments were given.
  def args
    first = Array(@data).first
    first.is_a?(Array) ? first : (first.nil? ? [] : [first])
  end

  # First positional argument when it is a Hash (keyword-style params).
  # Returns {} otherwise.
  def params
    first = Array(@data).first
    first.is_a?(Hash) ? first : {}
  end

  # ─── Helpers ────────────────────────────────────────────────────────

  # GET an HTTP(S) URL with redirect following. Returns Net::HTTPResponse,
  # or nil on failure. Never raises.
  #
  #   resp = http_get("https://api.github.com/repos/ZhgChgLi/linkyee")
  #   return 0 unless resp&.is_a?(Net::HTTPSuccess)
  def http_get(url, headers: {}, redirect_limit: 5, timeout: 15)
    return nil if redirect_limit <= 0

    uri = URI(url)
    req = Net::HTTP::Get.new(uri)
    default_headers.merge(headers).each { |k, v| req[k] = v }

    res = Net::HTTP.start(
      uri.hostname, uri.port,
      use_ssl: uri.scheme == 'https',
      open_timeout: timeout, read_timeout: timeout
    ) { |http| http.request(req) }

    case res
    when Net::HTTPRedirection
      http_get(res['location'], headers: headers, redirect_limit: redirect_limit - 1, timeout: timeout)
    else
      res
    end
  rescue StandardError => e
    log("http_get(#{url}) failed: #{e.class}: #{e.message}")
    nil
  end

  # GET a URL and parse the body as JSON. Returns parsed value, or `default`
  # on failure (network error, non-2xx, malformed JSON).
  def http_get_json(url, headers: {}, default: nil, **opts)
    res = http_get(url, headers: { 'Accept' => 'application/json' }.merge(headers), **opts)
    return default unless res.is_a?(Net::HTTPSuccess)

    JSON.parse(res.body)
  rescue JSON::ParserError => e
    log("http_get_json(#{url}) parse failed: #{e.message}")
    default
  end

  # Cache a value with optional disk persistence across builds.
  #
  #   cache("gh:#{repo}") { http_get_json(...) }            # in-memory only (per build)
  #   cache("gh:#{repo}", ttl: 3600) { http_get_json(...) } # disk-backed, 1h TTL
  #
  # Disk-backed caching is important for plugins hitting rate-limited APIs
  # (GitHub's unauth limit is 60/hour) — frequent rebuilds during local
  # development would otherwise blow through the budget within minutes.
  # Cache files live under ./.linkyee-cache/ (gitignored).
  #
  # Nil results are NEVER cached — that lets a failing fetch (rate limit,
  # network blip) be retried on the next build instead of pinning a bad
  # value for the full TTL.
  def cache(key, ttl: nil)
    return Plugin.cache_store[key] if Plugin.cache_store.key?(key)

    if ttl
      path = Plugin.disk_cache_path(key)
      if File.exist?(path) && (Time.now.to_i - File.mtime(path).to_i) < ttl
        begin
          value = JSON.parse(File.read(path))
          Plugin.cache_store[key] = value
          return value
        rescue JSON::ParserError
          # Treat corrupt cache as a miss; recompute below.
        end
      end
    end

    value = yield
    if !value.nil?
      Plugin.cache_store[key] = value
      if ttl
        path = Plugin.disk_cache_path(key)
        FileUtils.mkdir_p(File.dirname(path))
        File.write(path, JSON.generate(value))
      end
    end
    value
  end

  # Print a build-log line with the plugin's class name as prefix.
  def log(msg)
    warn "[#{self.class.name}] #{msg}"
  end

  def self.cache_store
    @cache_store ||= {}
  end

  def self.disk_cache_dir
    './.linkyee-cache'
  end

  def self.disk_cache_path(key)
    require 'digest'
    File.join(disk_cache_dir, "#{Digest::SHA1.hexdigest(key)}.json")
  end

  private

  def default_headers
    {
      'User-Agent' => 'linkyee/1.0 (+https://github.com/ZhgChgLi/linkyee)',
      'Accept' => '*/*'
    }
  end
end
