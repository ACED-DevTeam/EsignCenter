# frozen_string_literal: true

# The help centre's table of contents (Session 10 Phase B).
#
# ONE source of truth, and it is the YAML file that sits beside the prose:
# app/views/help/articles/REGISTRY.yml lists the ten articles in the order
# they appear, and each entry names the partial next to it
# (app/views/help/articles/<slug>.html.erb). Nothing about an article is typed
# twice — a title changes in one place, and an article with no partial (or a
# partial with no entry) fails the spec rather than rendering a blank page.
#
# There are deliberately no PRODUCT NUMBERS here or in the prose: every cap,
# price and window in an article body is rendered from the constant that
# enforces it (Quotas::Limits, StripeBilling, Accounts::Retention …), so a
# help page cannot promise a limit the app does not apply.
module HelpCenter
  ARTICLES_DIR = Rails.root.join('app/views/help/articles')
  REGISTRY_PATH = ARTICLES_DIR.join('REGISTRY.yml')

  # One article. `template` is what the view renders — a TEMPLATE, not a
  # partial, so the writer's files keep their plain `<slug>.html.erb` names
  # instead of Rails' leading underscore. `section` is the heading the article
  # is grouped under on /help.
  Article = Struct.new(:slug, :title, :summary, :section, :updated_on, :reading_minutes) do
    def template
      "help/articles/#{slug}"
    end

    def to_param
      slug
    end
  end

  # Raised for a slug nobody has written; the controller turns it into a 404
  # the same way LegalController does for an unknown document.
  UnknownArticle = Class.new(StandardError)

  # The same reasoning as OpenapiDocument::CACHE_LOCK: /help is a public page
  # several Puma threads can enter at once on a cold process, and a thread
  # handed a half-built cache would call `group_by` on nil and 500. The pair is
  # published after the parse, under the lock, and a failed parse publishes
  # nothing.
  CACHE_LOCK = Mutex.new

  module_function

  # Parsed once and re-parsed when the file itself changes, so the writer sees
  # an edit to the registry without a restart and a running server never pays
  # for the parse twice.
  def articles
    mtime = REGISTRY_PATH.mtime
    cached = @cache

    return cached.last if cached && cached.first == mtime

    # Parsed OUTSIDE the lock, which only publishes the result: the parse
    # builds `Article`s and can trigger a Zeitwerk load, and a load cannot
    # complete while another thread is parked on this mutex holding the
    # executor's share lock (review 1 loop 2, N4 — see OpenapiDocument.json).
    # Two threads racing a cold cache both parse the same file into the same
    # answer.
    loaded = load_articles

    CACHE_LOCK.synchronize { @cache = [mtime, loaded].freeze }

    loaded
  end

  def load_articles
    YAML.safe_load_file(REGISTRY_PATH, permitted_classes: [Date]).map do |row|
      Article.new(
        slug: row.fetch('slug'),
        title: row.fetch('title'),
        summary: row.fetch('summary'),
        section: row.fetch('section'),
        updated_on: row.fetch('updated_on').to_date,
        reading_minutes: row.fetch('reading_minutes').to_i
      )
    end.freeze
  end

  def slugs
    articles.map(&:slug)
  end

  def article(slug)
    articles.find { |candidate| candidate.slug == slug.to_s }
  end

  def article!(slug)
    article(slug) || raise(UnknownArticle, "no help article #{slug.inspect}")
  end

  # The index's groups: section heading => its articles, in registry order.
  # Sections are ordered by where they first appear in the registry, so the
  # writer controls both orderings from the one file.
  def sections
    articles.group_by(&:section)
  end

  # The reading order: the order the index draws the cards in, which is the
  # registry order regrouped by section. The registry is written so the two are
  # already the same (REGISTRY.yml's header says so and help_spec enforces it);
  # walking the grouping anyway means an entry parked away from its section can
  # only ever make the index look odd, never send a reader out of the section
  # they are part-way through.
  def ordered_articles
    sections.values.flatten
  end

  # The article before and after this one, for the foot of an article page, in
  # the order the index offers them. The list does not wrap: the first has no
  # previous and the last no next.
  def neighbours(article)
    ordered = ordered_articles
    index = ordered.index(article)

    [index.positive? ? ordered[index - 1] : nil, ordered[index + 1]]
  end
end
