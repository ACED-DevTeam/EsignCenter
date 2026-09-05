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

  module_function

  # The served JSON, as a String (already generated: nothing downstream needs
  # to re-serialize half a megabyte).
  def json
    mtime = PATH.mtime

    return @json if defined?(@mtime) && @mtime == mtime

    @mtime = mtime
    @json = JSON.generate(document)
  end

  # The parsed, rewritten document. Public so the golden spec can assert
  # against the same object the JSON is generated from.
  def document
    parsed = JSON.parse(PATH.read.gsub(PLACEHOLDER_ORIGIN, app_url))

    parsed['servers'] = [{ 'url' => api_url, 'description' => "#{Docuseal.product_name} API" }]
    parsed['info'] ||= {}
    parsed['info']['contact'] = parsed['info'].fetch('contact', {}).merge('url' => CONTACT_URL)

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
