# frozen_string_literal: true

# The four ready-made documents a brand-new customer account starts with
# (D50): a mutual NDA, a freelance service agreement, a photo and video
# release and a bill of sale. They exist so that the first thing a person sees
# after signing up is a dashboard with something on it they could actually
# send, instead of an empty shelf and a file picker.
#
# The PDFs and `manifest.yml` beside this file are generated together by
# `rake starter_templates:generate` (lib/starter_templates/generator.rb) and
# committed; the manifest names each
# template's signers and gives every fill-in blank its page and its rectangle
# in the app's normalized 0-1 page coordinates, which is the shape
# Template#fields stores.
#
# Seeding goes through `Templates::CreateAttachments` and
# `Templates::ProcessDocument` — the SAME path every upload takes — so a
# starter template has its page count, its preview images and its annotations
# exactly as an uploaded one does. There is no second way to put a document
# into an account.
module StarterTemplates
  DIR = Rails.root.join('lib/starter_templates')
  MANIFEST_PATH = DIR.join('manifest.yml')

  # The marker on the template itself. The first-run checklist asks "has this
  # person chosen a document of their own yet?", and it must be able to tell a
  # template we put there from one they uploaded — the author cannot, because
  # both are authored by the account's admin.
  STARTER_PREFERENCE_KEY = 'starter'

  # The one unique index `seed!` is allowed to swallow a collision on: the
  # seeding marker's (account_id, key). Anything else that raises
  # RecordNotUnique under `seed!` is a bug, and a bug reported as "somebody
  # else did it" is the class of bug that hides for months (loop 3, N7).
  MARKER_INDEX = 'index_account_configs_on_account_id_and_key'

  # `templates.preferences` is a text column holding JSON, so the marker is
  # cast for a lookup; an empty string is treated as an empty object rather
  # than blowing the cast up. FirstRunChecklist::NON_STARTER_TEMPLATE_SQL asks
  # the negation of this same question.
  MARKED_SQL = <<~SQL.squish
    COALESCE(NULLIF(templates.preferences, ''), '{}')::jsonb ->> :key = 'true'
  SQL

  module_function

  # The templates in `relation` that are still one of the four we put there.
  def marked(relation)
    relation.where([MARKED_SQL, { key: STARTER_PREFERENCE_KEY }])
  end

  def manifest
    @manifest ||= YAML.safe_load(MANIFEST_PATH.read).fetch('templates').freeze
  end

  def slugs
    manifest.pluck('slug')
  end

  # Seed `account`, or do nothing. Idempotent twice over: the marker config
  # says "this account has been seeded" even after the templates have been
  # deleted, and an account that already holds ANY template is one whose owner
  # has started work — a second run must never drop four documents on top of
  # it. Both checks and the writes are one transaction, so a failure half way
  # leaves neither templates nor marker and the account looks untouched.
  #
  # Returns the templates it created, or nil when it declined.
  def seed!(account)
    return unless account.customer?
    return if seeded?(account)

    author = admin_for(account)

    return if author.nil?

    templates = nil

    ApplicationRecord.transaction do
      # The marker goes in FIRST, and its unique index on (account_id, key) is
      # what makes two workers racing the same brand-new account safe: the
      # loser raises RecordNotUnique here, before it has written a document,
      # and its whole transaction is rolled back.
      account.account_configs.create!(key: AccountConfig::STARTER_TEMPLATES_SEEDED_KEY,
                                      value: { 'seeded_at' => Time.current.utc.iso8601 })

      templates = manifest.map { |spec| create_template!(account, author, spec) }
    end

    # Outside the transaction: the search index is a read model, and a
    # reindex enqueued before the commit would race the rows it is about to
    # be asked to read.
    SearchEntries.enqueue_reindex(templates)

    templates
  rescue ActiveRecord::RecordNotUnique => e
    # Two workers racing the same brand-new account. The marker's unique index
    # rolled this one back before it wrote a document, which is the outcome the
    # idempotency check above is asking for — so it is an ordinary "somebody
    # else did it", not something to wake an operator for.
    #
    # Narrowed to THAT index (session 10, seam L2). This rescue covers the
    # whole method — the marker, four templates, their attachments, the
    # document processing and the reindex — and a class-wide rescue would file
    # a unique-index bug in any of them as the same well-formed shrug, with no
    # ErrorReport, because the exception never reaches StarterTemplatesJob.
    raise unless e.message.include?(MARKER_INDEX)

    nil
  end

  def seeded?(account)
    account.account_configs.exists?(key: AccountConfig::STARTER_TEMPLATES_SEEDED_KEY) ||
      account.templates.exists?
  end

  # The account's own admin, oldest first: on a fresh sign-up there is exactly
  # one, and it is the person who just signed up.
  def admin_for(account)
    account.users.active.admins.order(:id).first
  end

  def create_template!(account, author, spec)
    template = account.templates.new(
      author:,
      name: spec['name'],
      preferences: { STARTER_PREFERENCE_KEY => true },
      submitters: spec['submitters'].map { |name| { 'name' => name, 'uuid' => SecureRandom.uuid } }
    )

    Templates.maybe_assign_access(template)

    template.save!

    documents, = Templates::CreateAttachments.call(template, { files: [uploaded_file(spec['slug'])] })
    document = documents.first

    template.update!(schema: [Templates::CreateAttachments.schema_item(document)],
                     fields: build_fields(spec, template, document))

    template
  end

  # The manifest names each field's signer by role ("Client"), which is how a
  # human reads it; the template stores the uuid the role was given when the
  # row above was built.
  def build_fields(spec, template, document)
    submitter_uuids = template.submitters.index_by { |s| s['name'] }.transform_values { |s| s['uuid'] }

    spec['fields'].map do |field|
      {
        'uuid' => SecureRandom.uuid,
        'submitter_uuid' => submitter_uuids.fetch(field['submitter']),
        'name' => field['name'],
        'type' => field['type'],
        'required' => field['required'],
        'preferences' => {},
        'areas' => [
          {
            'x' => field['area']['x'],
            'y' => field['area']['y'],
            'w' => field['area']['w'],
            'h' => field['area']['h'],
            'attachment_uuid' => document.uuid,
            'page' => field['page']
          }
        ]
      }
    end
  end

  # CreateAttachments takes what a browser upload gives a controller, so the
  # committed file is handed to it in exactly that shape rather than through a
  # side door of its own.
  def uploaded_file(slug)
    tempfile = Tempfile.new([slug, '.pdf'])
    tempfile.binmode
    tempfile.write(DIR.join("#{slug}.pdf").binread)
    tempfile.rewind

    ActionDispatch::Http::UploadedFile.new(tempfile:, filename: "#{slug}.pdf",
                                           type: Templates::CreateAttachments::PDF_CONTENT_TYPE)
  end
end
