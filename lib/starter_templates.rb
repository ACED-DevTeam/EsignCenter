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

  # The second marker, beside the first and in the same place, so nothing new
  # had to be added to the schema for it (review 10, A-F2).
  #
  # It says something narrower than `starter`: this is a starter document
  # NOBODY HAS OPENED. It is written by `create_template!` as its very last
  # act — after the file, the schema and the fields are on the row — and it is
  # taken off again by the first save of any kind
  # (Template#forget_starter_pristine_marker).
  #
  # It exists for one decision: when somebody who signed up alone joins a team
  # that also signed up self-serve, the four duplicate starters they never
  # used are dropped rather than landing the team with eight cards
  # (Accounts::MoveUser). "Never used" was read off submissions and share
  # links, which are the traces of SENDING a document — and a person who
  # opened a starter, renamed its fields and saved it has left neither, so
  # their work was destroyed as a duplicate. Editing always writes the row,
  # so the row is where the answer is.
  STARTER_PRISTINE_KEY = 'starter_pristine'

  # The one unique index `seed!` is allowed to swallow a collision on: the
  # seeding marker's (account_id, key). Anything else that raises
  # RecordNotUnique under `seed!` is a bug, and a bug reported as "somebody
  # else did it" is the class of bug that hides for months (loop 3, N7).
  MARKER_INDEX = 'index_account_configs_on_account_id_and_key'

  # `templates.preferences` is a text column holding JSON, so the marker is
  # cast for a lookup; an empty string is treated as an empty object rather
  # than blowing the cast up.
  MARKER_SQL = <<~SQL.squish
    COALESCE(NULLIF(templates.preferences, ''), '{}')::jsonb ->> :key
  SQL

  # The two directions of ONE question, both built from the cast above. The
  # first-run checklist asks the negation of what seeding asks, and it used to
  # ask it in a SQL string of its own, in a file of its own — two hand-written
  # copies of the same cast, either of which could be corrected without the
  # other. `IS DISTINCT FROM` rather than `<>`, because a template that carries
  # no marker at all reads NULL and NULL is not a starter.
  MARKED_SQL = "#{MARKER_SQL} = 'true'".freeze
  NOT_MARKED_SQL = "#{MARKER_SQL} IS DISTINCT FROM 'true'".freeze

  module_function

  # The templates in `relation` that are still one of the four we put there.
  def marked(relation)
    relation.where(marked_condition)
  end

  # ...and the ones in it that are not: a document of the account's own.
  def not_marked(relation)
    relation.where(not_marked_condition)
  end

  # ...and the ones nobody has opened since we put them there. Same cast, same
  # column, a different key.
  def pristine(relation)
    relation.where(pristine_condition)
  end

  def marked_condition
    [MARKED_SQL, { key: STARTER_PREFERENCE_KEY }]
  end

  def pristine_condition
    [MARKED_SQL, { key: STARTER_PRISTINE_KEY }]
  end

  def not_marked_condition
    [NOT_MARKED_SQL, { key: STARTER_PREFERENCE_KEY }]
  end

  # The same question as a finished SQL fragment, for the one caller that needs
  # it somewhere `where` cannot go: the checklist's ORDER BY.
  def not_marked_sql
    Template.sanitize_sql_array(not_marked_condition)
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

    # LAST, and with `update_columns` on purpose. Seeding a template is
    # several saves — the row, its attachments, then its schema and fields —
    # and the marker means "nobody has saved this since we finished", so it
    # can only be written once we have. `update_columns` is what keeps it
    # there: an ordinary save would run the callback that takes it off again.
    template.update_columns(preferences: template.preferences.merge(STARTER_PRISTINE_KEY => true),
                            updated_at: Time.current)
    template.reload

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
