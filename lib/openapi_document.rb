# frozen_string_literal: true

# The OpenAPI description this instance serves at /docs/openapi.json, and the
# one the API reference at /docs/api reads (ApiReferenceController).
#
# docs/openapi.json is kept in the repository as the AUTHORED document — it is
# reviewed, diffed and shipped with the code — and it is written for a generic
# instance: every example URL in it is `https://your-instance.example.com`. A
# reader must not be told to curl somebody else's hostname, so the served copy
# is that file with the placeholder origin rewritten to this instance's own
# APP_URL, `servers[0]` pointed at this instance's /api, and the contact link
# pointed at the support form rather than a source repository.
#
# The whole file is half a megabyte, so the transformed copy is built once per
# process and rebuilt only when the file on disk changes: a deploy replaces the
# file (new mtime) and the next request pays for one parse.
module OpenapiDocument
  PATH = Rails.root.join('docs/openapi.json')

  # The origin the authored document uses for every example. Rewritten whole,
  # scheme included, so `https://your-instance.example.com/file/x.pdf` becomes
  # this instance's own origin however it is configured (http in development).
  PLACEHOLDER_ORIGIN = 'https://your-instance.example.com'

  # Where a developer with a question should go. The support FORM, not the
  # mailbox: it is the door with a person behind it and a topic for the API.
  CONTACT_URL = 'https://esigncenter.com/support'

  # An hour. The document changes only on a deploy, and a reference page that
  # re-downloads half a megabyte on every visit is its own problem.
  CACHE_MAX_AGE = 1.hour

  # Puma serves this from several threads at once, and the very first requests
  # after a deploy arrive together. The cached pair is published as ONE frozen
  # array under this lock, after the value exists — a thread that arrives while
  # another is still generating waits for it rather than being handed the
  # half-built cache, and a read that raises leaves no pair behind at all, so
  # the next request tries again instead of serving `null` for an hour behind a
  # public max-age.
  CACHE_LOCK = Mutex.new

  module_function

  # The served JSON, as a String (already generated: nothing downstream needs
  # to re-serialize half a megabyte).
  def json
    mtime = PATH.mtime
    cached = @cache

    return cached.last if cached && cached.first == mtime

    CACHE_LOCK.synchronize do
      # Another thread may have generated it while this one waited.
      cached = @cache

      return cached.last if cached && cached.first == mtime

      generated = JSON.generate(document)
      @cache = [mtime, generated].freeze

      generated
    end
  end

  # The parsed, rewritten document. Public so the golden spec can assert
  # against the same object the JSON is generated from.
  def document
    parsed = JSON.parse(PATH.read.gsub(PLACEHOLDER_ORIGIN, app_url))

    parsed['servers'] = [{ 'url' => api_url, 'description' => "#{Docuseal.product_name} API" }]
    parsed['info'] ||= {}
    # The support FORM is the whole contact block. `email` is dropped rather
    # than repointed: /docs/openapi.json is a public, indexable, machine-read
    # endpoint, and an address published there is an address harvested there —
    # the form is the door with a person behind it, and it is the one the rest
    # of the site sends people to.
    parsed['info']['contact'] = parsed['info'].fetch('contact', {}).except('email').merge('url' => CONTACT_URL)

    parsed
  end

  def app_url
    Docuseal::DEFAULT_APP_URL.chomp('/')
  end

  def api_url
    "#{app_url}/api"
  end

  # Every path the authored document describes, for the golden spec: serving a
  # rewritten copy must never DROP an operation.
  def authored_paths
    JSON.parse(PATH.read).fetch('paths').keys
  end
end
