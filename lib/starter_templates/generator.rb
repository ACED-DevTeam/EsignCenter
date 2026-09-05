# frozen_string_literal: true

module StarterTemplates
  # How the committed starter-template PDFs and their manifest are made:
  # `bundle exec rake starter_templates:generate`.
  #
  # It is here, and committed, because the PDFs and `manifest.yml` HAVE to
  # agree. The manifest gives every fill-in blank a rectangle on a page, and
  # the only thing that knows where a blank really landed is the code that
  # drew it — so one run produces both, and changing a word of an agreement is
  # a matter of editing the prose below and running the task again rather than
  # measuring a PDF by hand.
  #
  # The layout is deliberately hand-rolled rather than flowed by HexaPDF's
  # composer: the line breaking is done here, with the real font metrics, so
  # the page a blank lands on and the box it occupies are known while it is
  # drawn instead of being discovered afterwards.
  #
  # Nothing in here runs in the application.
  module Generator
    PAGE_W = 612.0 # US Letter, in points
    PAGE_H = 792.0
    MARGIN_L = 64.0
    MARGIN_R = 64.0
    MARGIN_T = 62.0
    MARGIN_B = 58.0
    CONTENT_W = PAGE_W - MARGIN_L - MARGIN_R

    BODY_SIZE = 9.5
    BODY_LEADING = 13.0
    INK = [0.11, 0.13, 0.16].freeze
    MUTED = [0.42, 0.45, 0.5].freeze
    RULE = [0.72, 0.75, 0.79].freeze

    # Every starter template says this, in italics, under its title: these are
    # sensible starting points, not legal advice.
    REVIEW_NOTE = 'Starter template — review before use.'

    MANIFEST_HEADER = <<~YAML
      # The four starter templates seeded into a brand-new customer account at
      # sign-up (Session 10 A1, D50). GENERATED — do not hand-edit: this file and
      # the PDFs beside it come out of one run of
      # `rake starter_templates:generate` (lib/starter_templates/generator.rb),
      # which lays the pages out with real font metrics and emits each blank's
      # rectangle from where it actually drew it. Areas are the app's normalized
      # 0-1 page coordinates (x/y from the top-left of the page), exactly as
      # Template#fields stores them.
    YAML

    # One PDF, laid out a line at a time. Every `record`ed blank remembers the
    # page it was drawn on and the box it filled.
    class Sheet
      attr_reader :fields

      def initialize
        @doc = HexaPDF::Document.new
        @metrics = {
          regular: @doc.fonts.add('Helvetica'),
          bold: @doc.fonts.add('Helvetica', variant: :bold),
          italic: @doc.fonts.add('Helvetica', variant: :italic)
        }
        @fields = []
        @page_index = -1
        new_page
      end

      def new_page
        @page_index += 1
        @canvas = @doc.pages.add([0, 0, PAGE_W, PAGE_H]).canvas
        @y = PAGE_H - MARGIN_T
      end

      # Start a new page unless `height` points still fit under the cursor.
      def keep_together(height)
        new_page if @y - height < MARGIN_B
      end

      def gap(points)
        @y -= points
        new_page if @y < MARGIN_B
      end

      def title(text)
        keep_together(40)
        draw_text(text, MARGIN_L, 17, style: :bold)
        gap(15)
      end

      def note(text)
        draw_text(text, MARGIN_L, 8.5, style: :italic, color: MUTED)
        gap(20)
      end

      def heading(text)
        keep_together(BODY_LEADING * 3)
        gap(6)
        draw_text(text, MARGIN_L, 10.5, style: :bold)
        gap(BODY_LEADING + 1)
      end

      def para(text)
        wrap(text, CONTENT_W, BODY_SIZE).each do |line|
          keep_together(BODY_LEADING)
          draw_text(line, MARGIN_L, BODY_SIZE)
          gap(BODY_LEADING)
        end
        gap(4)
      end

      def rule
        keep_together(10)
        @canvas.save_graphics_state do
          @canvas.stroke_color(*RULE).line_width(0.6)
          @canvas.line(MARGIN_L, @y + 4, PAGE_W - MARGIN_R, @y + 4).stroke
        end
        gap(12)
      end

      # A row of labelled blanks, always laid out on a `columns`-wide grid so
      # that one blank in a two-column row takes half the width rather than
      # stretching across the page and running into the rule below it.
      def blanks(entries, height: 17.0, columns: 2)
        columns = [columns, entries.size].max
        keep_together(height + 20)
        column_w = (CONTENT_W - (12.0 * (columns - 1))) / columns

        entries.each_with_index do |entry, index|
          left = MARGIN_L + ((column_w + 12.0) * index)

          caption(entry[:label], left, @y)
          underline(left, @y - 4.0 - height, column_w)

          record(entry[:field], left, @y - 4.0, column_w, height) if entry[:field]
        end

        gap(height + 18)
      end

      # A tick box: a small square with its question beside it, the way a
      # printed form asks a yes-or-no question.
      def checkbox(label, field, size: 12.0)
        keep_together(size + 16)
        box_top = @y + 2.0

        @canvas.save_graphics_state do
          @canvas.stroke_color(*RULE).line_width(0.9)
          @canvas.rectangle(MARGIN_L, box_top - size, size, size).stroke
        end

        draw_text(label, MARGIN_L + size + 9, BODY_SIZE)
        record(field, MARGIN_L, box_top, size, size)

        gap(size + 10)
      end

      # The signature strip: a tall box per signer with its label under the
      # rule, the way a paper contract leaves room for a hand.
      def signature_row(entries, height: 42.0)
        keep_together(height + 34)
        column_w = (CONTENT_W - (16.0 * (entries.size - 1))) / entries.size

        entries.each_with_index do |entry, index|
          left = MARGIN_L + ((column_w + 16.0) * index)
          bottom = @y - height

          underline(left, bottom, column_w)
          caption(entry[:label], left, bottom - 11)

          record(entry[:field], left, @y, column_w, height) if entry[:field]
        end

        gap(height + 44)
      end

      def write(path)
        @doc.write(path, optimize: true)
      end

      private

      def draw_text(text, left, size, style: :regular, color: INK)
        @canvas.save_graphics_state do
          @canvas.fill_color(*color)
          @canvas.font('Helvetica', size:, variant: style == :regular ? :none : style)
          @canvas.text(text, at: [left, @y])
        end
      end

      def caption(text, left, baseline)
        @canvas.save_graphics_state do
          @canvas.fill_color(*MUTED)
          @canvas.font('Helvetica', size: 7.5, variant: :none)
          @canvas.text(text.upcase, at: [left, baseline])
        end
      end

      def underline(left, bottom, width)
        @canvas.save_graphics_state do
          @canvas.stroke_color(*RULE).line_width(0.7)
          @canvas.line(left, bottom, left + width, bottom).stroke
        end
      end

      def record(field, left, top, width, height)
        @fields << field.merge(
          'page' => @page_index,
          'area' => {
            'x' => (left / PAGE_W).round(6),
            'y' => ((PAGE_H - top) / PAGE_H).round(6),
            'w' => (width / PAGE_W).round(6),
            'h' => (height / PAGE_H).round(6)
          }
        )
      end

      def width_of(text, size)
        @metrics[:regular].decode_utf8(text).sum(&:width) / 1000.0 * size
      end

      def wrap(text, width, size)
        lines = []
        current = +''

        text.split(/\s+/).each do |word|
          candidate = current.empty? ? word : "#{current} #{word}"

          if width_of(candidate, size) <= width
            current = candidate
          else
            lines << current unless current.empty?
            current = word
          end
        end

        lines << current unless current.empty?
        lines
      end
    end

    class << self
      def field(name, type, submitter, required: true)
        { 'name' => name, 'type' => type, 'required' => required, 'submitter' => submitter }
      end

      def blank(label, field)
        { label:, field: }
      end
    end

    # ------------------------------------------------------------- documents
    #
    # Each one is DATA: a slug, the roles that sign it, and the blocks the
    # sheet above draws in order. Prose lives here so that changing a clause is
    # an edit and a re-run, never a measurement.

    NDA_FIRST = 'First Party'
    NDA_SECOND = 'Second Party'

    MUTUAL_NDA = {
      'slug' => 'mutual-nda',
      'name' => 'Mutual Non-Disclosure Agreement',
      'description' => 'Two parties agree to keep each other\'s information private before they work together.',
      'submitters' => [NDA_FIRST, NDA_SECOND],
      'blocks' => [
        [:title, 'Mutual Non-Disclosure Agreement'],
        [:note, REVIEW_NOTE],
        [:para, 'This agreement is between the two parties named below. Each of them expects to share ' \
                'information with the other that is not public, and each agrees to look after the other ' \
                'party\'s information on the terms set out here.'],
        [:gap, 6],
        [:blanks, [blank('First party name', field('First Party name', 'text', NDA_FIRST)),
                   blank('First party company',
                         field('First Party company', 'text', NDA_FIRST, required: false))]],
        [:blanks, [blank('Second party name', field('Second Party name', 'text', NDA_SECOND)),
                   blank('Second party company',
                         field('Second Party company', 'text', NDA_SECOND, required: false))]],
        [:blanks, [blank('Effective date', field('Effective date', 'date', NDA_FIRST))]],
        [:gap, 2],
        [:rule],
        [:heading, '1. What counts as confidential information'],
        [:para, 'Anything one party shares with the other that is marked confidential, or that a sensible ' \
                'person would understand to be private, is confidential information. Plans, pricing, ' \
                'customer lists, designs, source code and unreleased work are all included, whether they ' \
                'are shared on paper, by email or out loud.'],
        [:heading, '2. What is not covered'],
        [:para, 'Information that is already public without either party being at fault, that the receiving ' \
                'party already held before it was shared, that it works out independently without using the ' \
                'other party\'s information, or that somebody else passes on lawfully and without restriction.'],
        [:heading, '3. How each party may use it'],
        [:para, 'Only to consider or carry out the work the parties are discussing. Neither party sells, ' \
                'publishes or passes on the other\'s confidential information, and neither uses it to compete ' \
                'with the party that shared it.'],
        [:heading, '4. Who may see it'],
        [:para, 'Only the people who need it for that purpose — employees, directors and professional ' \
                'advisers — and only where they are already under a duty of confidence at least as strict ' \
                'as this one. Each party stays responsible for the people it shares with.'],
        [:heading, '5. How long the duty lasts'],
        [:para, 'Each party keeps the other\'s confidential information private for three years from the ' \
                'day it was shared, and protects it with at least the same care it uses for its own ' \
                'confidential material.'],
        [:heading, '6. Returning or deleting it'],
        [:para, 'On written request, each party returns or deletes what it holds, apart from copies kept ' \
                'automatically in routine backups and anything either party has to keep by law. Copies kept ' \
                'that way stay confidential under this agreement.'],
        [:heading, '7. No transfer of ownership, no warranty'],
        [:para, 'Sharing information gives the receiving party no ownership of it and no licence beyond the ' \
                'purpose above. Neither party promises that the information it shares is accurate or complete.'],
        [:heading, '8. Ending this agreement'],
        [:para, 'Either party may end this agreement by giving the other 30 days written notice. The duty ' \
                'of confidence in clause 5 carries on for information shared before it ended.'],
        [:gap, 6],
        [:keep_together, 190],
        [:rule],
        [:para, 'Each party confirms that the person signing below is authorised to sign for it.'],
        [:gap, 4],
        [:signature_row, [blank('First party signature', field('First Party signature', 'signature', NDA_FIRST)),
                          blank('Second party signature',
                                field('Second Party signature', 'signature', NDA_SECOND))]],
        [:blanks, [blank('Date signed', field('First Party date signed', 'date', NDA_FIRST)),
                   blank('Date signed', field('Second Party date signed', 'date', NDA_SECOND))]]
      ]
    }.freeze

    CLIENT = 'Client'
    CONTRACTOR = 'Contractor'

    FREELANCE_SERVICE_AGREEMENT = {
      'slug' => 'freelance-service-agreement',
      'name' => 'Freelance Service Agreement',
      'description' => 'A client and a freelancer agree the work, the fee and the start date.',
      'submitters' => [CLIENT, CONTRACTOR],
      'blocks' => [
        [:title, 'Freelance Service Agreement'],
        [:note, REVIEW_NOTE],
        [:para, 'This agreement sets out the work one person or business (the contractor) will do for ' \
                'another (the client), what it costs and when it starts.'],
        [:gap, 6],
        [:blanks, [blank('Client name', field('Client name', 'text', CLIENT)),
                   blank('Client company', field('Client company', 'text', CLIENT, required: false))]],
        [:blanks, [blank('Contractor name', field('Contractor name', 'text', CONTRACTOR)),
                   blank('Contractor company',
                         field('Contractor company', 'text', CONTRACTOR, required: false))]],
        [:blanks, [blank('Work to be done', field('Scope of work', 'text', CLIENT))], { height: 34.0, columns: 1 }],
        [:blanks, [blank('Fee', field('Fee', 'text', CLIENT)),
                   blank('Start date', field('Start date', 'date', CLIENT))]],
        [:gap, 2],
        [:rule],
        [:heading, '1. The work'],
        [:para, 'The contractor will carry out the work described above with reasonable skill and care, and ' \
                'will tell the client promptly if anything is going to be late or cost more than agreed. ' \
                'Anything outside that description is extra work, and is only chargeable if the client ' \
                'agrees to it in writing first.'],
        [:heading, '2. Fee and invoices'],
        [:para, 'The client pays the fee above. The contractor invoices for it, and the client pays each ' \
                'invoice within 14 days of receiving it. Agreed expenses are invoiced at cost with receipts ' \
                'attached.'],
        [:heading, '3. An independent contractor'],
        [:para, 'The contractor is self-employed, not an employee of the client. The contractor decides how ' \
                'and when the work is done, uses their own equipment unless the parties agree otherwise, and ' \
                'is responsible for their own taxes and insurance.'],
        [:heading, '4. Who owns the work'],
        [:para, 'Once the contractor has been paid in full, everything created specifically for the client ' \
                'under this agreement belongs to the client. Tools, libraries and know-how the contractor ' \
                'brought with them stay the contractor\'s, and the client may use them as part of the ' \
                'delivered work.'],
        [:heading, '5. Confidentiality'],
        [:para, 'Each party keeps the other\'s private business information to itself, uses it only for this ' \
                'work, and carries on doing so after the work ends.'],
        [:heading, '6. Ending the agreement'],
        [:para, 'Either party may end this agreement by giving the other 14 days written notice. The client ' \
                'pays for work done up to that point, and the contractor hands over whatever has been ' \
                'completed and paid for.'],
        [:gap, 6],
        [:keep_together, 190],
        [:rule],
        [:para, 'Both parties agree to the terms above.'],
        [:gap, 4],
        [:signature_row, [blank('Client signature', field('Client signature', 'signature', CLIENT)),
                          blank('Contractor signature',
                                field('Contractor signature', 'signature', CONTRACTOR))]],
        [:blanks, [blank('Date signed', field('Client date signed', 'date', CLIENT)),
                   blank('Date signed', field('Contractor date signed', 'date', CONTRACTOR))]]
      ]
    }.freeze

    PARTICIPANT = 'Participant'

    MEDIA_RELEASE = {
      'slug' => 'media-release',
      'name' => 'Photo & Video Release',
      'description' => 'One person gives permission for photos, video and audio of them to be used.',
      'submitters' => [PARTICIPANT],
      'blocks' => [
        [:title, 'Photo & Video Release'],
        [:note, REVIEW_NOTE],
        [:para, 'This form asks a person for permission to use photographs, video and audio recordings of ' \
                'them that are made as part of the project named below.'],
        [:gap, 6],
        [:blanks, [blank('Your full name', field('Participant name', 'text', PARTICIPANT)),
                   blank('Project or event', field('Project', 'text', PARTICIPANT))]],
        [:blanks, [blank('Date', field('Date', 'date', PARTICIPANT))]],
        [:gap, 2],
        [:rule],
        [:heading, '1. What you are agreeing to'],
        [:para, 'You agree that photographs, video and audio recordings of you made for this project may be ' \
                'used in the ways described below. You are not being paid for this, and you are giving ' \
                'permission freely.'],
        [:heading, '2. How the recordings may be used'],
        [:para, 'For the project itself and for publicising it: on websites and social media, in printed ' \
                'material, in presentations and in press coverage. They may be edited, cropped or shortened, ' \
                'so long as the result is not misleading and does not put you in a false light.'],
        [:heading, '3. Your name'],
        [:para, 'Your name may be shown alongside the recordings, or left off, whichever the project decides ' \
                'unless you have asked in writing for it to be left off.'],
        [:heading, '4. Changing your mind'],
        [:para, 'You may withdraw this permission at any time by writing to the project. Material already ' \
                'published or printed before then can stay where it is, but nothing new will be published ' \
                'after your request arrives.'],
        [:heading, '5. Ownership'],
        [:para, 'The recordings belong to the person or organisation that made them. This form is your ' \
                'permission for them to be used, not a transfer of anything you own.'],
        [:gap, 6],
        [:keep_together, 210],
        [:rule],
        [:para, 'Initial here to confirm you have read and understood how the recordings may be used, and ' \
                'that you are giving this permission freely:'],
        [:gap, 4],
        [:blanks, [blank('Your initials', field('Consent initials', 'initials', PARTICIPANT))],
         { height: 22.0, columns: 3 }],
        [:checkbox, 'I am 18 years old or older', field('I am 18 or older', 'checkbox', PARTICIPANT)],
        [:para, 'If the person in the recordings is under 18, a parent or guardian should sign instead.'],
        [:gap, 8],
        [:signature_row, [blank('Signature', field('Signature', 'signature', PARTICIPANT))]]
      ]
    }.freeze

    SELLER = 'Seller'
    BUYER = 'Buyer'

    BILL_OF_SALE = {
      'slug' => 'bill-of-sale',
      'name' => 'Personal Property Bill of Sale',
      'description' => 'A seller and a buyer record the item, the price and the date it changed hands.',
      'submitters' => [SELLER, BUYER],
      'blocks' => [
        [:title, 'Personal Property Bill of Sale'],
        [:note, REVIEW_NOTE],
        [:para, 'This document records the sale of an item from one person to another, and the date the ' \
                'item changed hands.'],
        [:gap, 6],
        [:blanks, [blank('Seller name', field('Seller name', 'text', SELLER)),
                   blank('Buyer name', field('Buyer name', 'text', BUYER))]],
        [:blanks, [blank('Item sold', field('Item description', 'text', SELLER))],
         { height: 34.0, columns: 1 }],
        [:blanks, [blank('Price', field('Price', 'text', SELLER)),
                   blank('Date of sale', field('Date of sale', 'date', SELLER))]],
        [:gap, 2],
        [:rule],
        [:heading, '1. The sale'],
        [:para, 'The seller sells the item described above to the buyer for the price shown, and the buyer ' \
                'agrees to buy it on those terms. Payment and delivery both happen on the date of sale ' \
                'unless the parties have written something else below.'],
        [:heading, '2. The seller confirms'],
        [:para, 'That they own the item outright, that nobody else has a claim, loan or lien over it, and ' \
                'that they are free to sell it.'],
        [:heading, '3. Sold as it stands'],
        [:para, 'The item is sold as it is, where it is. The buyer has had the chance to examine it and is ' \
                'satisfied with its condition. The seller gives no warranty about how it will perform, ' \
                'beyond what the law requires.'],
        [:heading, '4. Risk and ownership'],
        [:para, 'Ownership and risk pass to the buyer when the price is paid in full and the item is handed ' \
                'over. From that moment the item is the buyer\'s responsibility.'],
        [:heading, '5. This is the whole agreement'],
        [:para, 'This document is the whole of what the parties agreed about this sale. Anything either ' \
                'party said beforehand that is not written here does not form part of it.'],
        [:gap, 6],
        [:keep_together, 190],
        [:rule],
        [:para, 'Both parties confirm the details above are correct.'],
        [:gap, 4],
        [:signature_row, [blank('Seller signature', field('Seller signature', 'signature', SELLER)),
                          blank('Buyer signature', field('Buyer signature', 'signature', BUYER))]],
        [:blanks, [blank('Date signed', field('Seller date signed', 'date', SELLER)),
                   blank('Date signed', field('Buyer date signed', 'date', BUYER))]]
      ]
    }.freeze

    DOCUMENTS = [MUTUAL_NDA, FREELANCE_SERVICE_AGREEMENT, MEDIA_RELEASE, BILL_OF_SALE].freeze

    # A starter PDF has no business being large: it is four pages of Helvetica
    # at most, and anything bigger means something has gone wrong.
    MAX_PDF_BYTES = 60_000

    class << self
      # Writes the four PDFs and manifest.yml into `dir`. Returns the manifest.
      def call(dir: StarterTemplates::DIR, io: $stdout)
        FileUtils.mkdir_p(dir)

        manifest = DOCUMENTS.map { |document| write_document(document, dir, io) }

        File.write(File.join(dir, 'manifest.yml'),
                   MANIFEST_HEADER + { 'templates' => manifest }.to_yaml.delete_prefix("---\n"))

        io.puts("manifest.yml written (#{manifest.sum { |t| t['fields'].size }} fields)")

        manifest
      end

      def write_document(document, dir, io)
        sheet = render(document)
        path = File.join(dir, "#{document['slug']}.pdf")

        sheet.write(path)

        size = File.size(path)

        raise "#{document['slug']}.pdf is #{size} bytes, over the #{MAX_PDF_BYTES} limit" if size > MAX_PDF_BYTES

        io.puts("#{document['slug']}.pdf — #{size} bytes, #{sheet.fields.size} fields")

        document.except('blocks').merge('fields' => sheet.fields)
      end

      def render(document)
        sheet = Sheet.new

        document['blocks'].each do |name, *args|
          # A trailing SYMBOL-keyed hash is the block's options (`height:`,
          # `columns:`); a trailing string-keyed one is a field definition and
          # is an argument like any other.
          options = args.last.is_a?(Hash) && args.last.keys.all?(Symbol) ? args.pop : {}

          sheet.public_send(name, *args, **options)
        end

        sheet
      end
    end
  end
end
