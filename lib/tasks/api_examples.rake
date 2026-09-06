# frozen_string_literal: true

# The sample files the API reference links to: `rake api_examples:generate`.
#
# docs/openapi.json describes four upload endpoints and each one points the
# reader at an example file on THIS instance's origin
# (lib/openapi_document.rb rewrites the authored placeholder host to ours), so
# those files have to exist under public/ or the getting-started path of the
# API reference ends at a 404 on our own domain.
#
# They are generated here and committed, for the same reason the starter
# templates are: the prose in them has to agree with the tag syntax the app
# actually parses, and a file nobody can regenerate is a file nobody dares
# correct. Nothing in here runs in the application.
namespace :api_examples do
  desc 'Regenerate the API-reference example files under public/examples'
  task generate: :environment do
    require 'hexapdf'
    require 'zip'

    FileUtils.mkdir_p(ApiExamples::DIR)

    # The Word example of the field-tag syntax is already in the repository as
    # a test fixture, and the fixture is the copy the parser is tested against:
    # serving a second, hand-made one would be serving a file nothing checks.
    FileUtils.cp(Rails.root.join('spec/fixtures/fieldtags.docx'), ApiExamples::DIR.join('fieldtags.docx'))

    ApiExamples.write_pdf(ApiExamples::DIR.join('fieldtags.pdf'), 'Field tags for PDF documents',
                          ApiExamples::FIELD_TAG_SECTIONS)
    ApiExamples.write_docx(ApiExamples::DIR.join('demo_template.docx'), 'Freelance agreement (example)',
                           ApiExamples::VARIABLE_SECTIONS)

    puts "Wrote #{Dir.children(ApiExamples::DIR).sort.join(', ')} to #{ApiExamples::DIR}"
  end
end

# The prose and the two writers. A module rather than the task body, so nothing
# here leaks into the top-level namespace and a future reader can find it.
module ApiExamples
  DIR = Rails.public_path.join('examples')

  PAGE_W = 612.0 # US Letter, in points
  PAGE_H = 792.0
  MARGIN = 64.0

  # The one description of the tag syntax, so the Word example and the PDF
  # example cannot drift apart. Each entry is [heading, [line, ...]].
  FIELD_TAG_SECTIONS = [
    ['Field tag attributes (attribute=value;)',
     ['name: field name',
      'role: name of the signer role (optional)',
      'type: text, signature, initials, date, image, file, select, checkbox ' \
      '(optional, default: text)',
      "options: comma separated 'select' type options",
      'required: set false to make the field optional (optional, default: true)',
      'default: field default value',
      'readonly: set true to make the field readonly (optional, default: false)']],
    ['Tag examples',
     ['Simple text field: {{Text Field}}',
      'Text fields for two signing parties: {{Field1;role=First Party}} {{Field2;role=Second Party}}',
      'Date field: {{DOB;type=date}}',
      'Signature: {{Signature}} or {{Sign here;type=signature}}',
      'Readonly with a default value: {{Name;readonly=true;default=Bob}}',
      'With a width, a height and every other attribute: ' \
      '{{Test;readonly=false;required=false;type=image;role=Second Party;width=200;height=30}}']]
  ].freeze

  VARIABLE_SECTIONS = [
    ['Dynamic content variables ([[name]])',
     ['A variable is replaced with the value you send in the `values` parameter.',
      'Client: [[client_name]]',
      'Project: [[project_name]]',
      'Fee: [[fee]]',
      'Start date: [[start_date]]']],
    ['Signature fields in the same document',
     ['Field tags work here too, so a generated document can be signed straight away.',
      'Client signature: {{Signature;role=Client}}',
      'Contractor signature: {{Signature;role=Contractor}}']]
  ].freeze

  module_function

  def write_pdf(path, title, sections)
    doc = HexaPDF::Document.new
    regular = doc.fonts.add('Helvetica')
    bold = doc.fonts.add('Helvetica', variant: :bold)
    canvas = doc.pages.add([0, 0, PAGE_W, PAGE_H]).canvas
    y = PAGE_H - MARGIN

    canvas.font(bold, size: 17).fill_color(0.11, 0.13, 0.16)
    canvas.text(title, at: [MARGIN, y])
    y -= 24

    canvas.font(regular, size: 9).fill_color(0.42, 0.45, 0.5)
    intro = ['Example file for the EsignCenter API. Put tags like these into your own PDF and the ' \
             'fields are placed where the tags are.']
    wrap(intro, regular, 9).each do |line|
      canvas.text(line, at: [MARGIN, y])
      y -= 13
    end
    y -= 16

    sections.each do |heading, lines|
      canvas.font(bold, size: 11).fill_color(0.11, 0.13, 0.16)
      canvas.text(heading, at: [MARGIN, y])
      y -= 17

      canvas.font(regular, size: 9.5).fill_color(0.11, 0.13, 0.16)
      wrap(lines, regular, 9.5).each do |line|
        canvas.text(line, at: [MARGIN, y])
        y -= 14
      end

      y -= 10
    end

    doc.write(path.to_s, optimize: true)
  end

  # Line breaking with the real font metrics, so nothing runs off the page.
  def wrap(lines, font, size)
    limit = PAGE_W - (MARGIN * 2)

    lines.flat_map do |line|
      line.split.each_with_object(['']) do |word, out|
        candidate = out.last.empty? ? word : "#{out.last} #{word}"

        if width_of(font, candidate, size) <= limit
          out[-1] = candidate
        else
          out << word
        end
      end
    end
  end

  def width_of(font, text, size)
    font.decode_utf8(text).sum(&:width) / 1000.0 * size
  end

  # A minimal, valid Word package: the three parts Word needs and nothing
  # else. Written by hand because the alternative is a document-authoring
  # dependency the application would then carry for one sample file.
  def write_docx(path, title, sections)
    body = [paragraph(title, bold: true, size: 32)]

    sections.each do |heading, lines|
      body << paragraph(heading, bold: true, size: 24)
      lines.each { |line| body << paragraph(line) }
    end

    FileUtils.rm_f(path)

    Zip::File.open(path.to_s, create: true) do |zip|
      zip.get_output_stream('[Content_Types].xml') { |io| io.write(CONTENT_TYPES_XML) }
      zip.get_output_stream('_rels/.rels') { |io| io.write(RELS_XML) }
      zip.get_output_stream('word/document.xml') { |io| io.write(document_xml(body)) }
    end
  end

  def paragraph(text, bold: false, size: 20)
    properties = bold ? "<w:rPr><w:b/><w:sz w:val=\"#{size}\"/></w:rPr>" : "<w:rPr><w:sz w:val=\"#{size}\"/></w:rPr>"

    "<w:p><w:r>#{properties}<w:t xml:space=\"preserve\">#{CGI.escapeHTML(text)}</w:t></w:r></w:p>"
  end

  def document_xml(body)
    <<~XML
      <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
      <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
        <w:body>#{body.join}</w:body>
      </w:document>
    XML
  end

  CONTENT_TYPES_XML = <<~XML
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
      <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
      <Default Extension="xml" ContentType="application/xml"/>
      <Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>
    </Types>
  XML

  RELS_XML = <<~XML
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
      <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>
    </Relationships>
  XML
end
