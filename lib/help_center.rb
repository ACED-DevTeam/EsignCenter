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

  module_function

  # Parsed once and re-parsed when the file itself changes, so the writer sees
  # an edit to the registry without a restart and a running server never pays
  # for the parse twice.
  def articles
    mtime = REGISTRY_PATH.mtime

    return @articles if defined?(@registry_mtime) && @registry_mtime == mtime

    @registry_mtime = mtime
    @articles = load_articles
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

  # The article before and after this one, for the foot of an article page.
  # The list does not wrap: the first has no previous and the last no next.
  def neighbours(article)
    index = articles.index(article)

    [index.positive? ? articles[index - 1] : nil, articles[index + 1]]
  end
end
