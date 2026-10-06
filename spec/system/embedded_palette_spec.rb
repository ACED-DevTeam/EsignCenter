# frozen_string_literal: true

RSpec.describe 'Embedded template palette', type: :system do
  it 'offers application fields for placement without dead palette editing controls' do
    account = create(:account, :internal)
    author = create(:user, account:)
    template = create(:template, account:, author:, only_field_types: %w[text])
    attrs = { template_id: template.id, embed_origin: 'https://crm.example.com',
              custom_fields: [{ name: 'loan.number', title: 'Loan number', type: 'text' }] }
    TemplateBuilderSessions::Create.call(user: author, attrs:)

    token = TemplateBuilderSessions::SerializeForApi.signed_token(template.reload)
    # Autosave uses this deployment's absolute APP_URL. Point that URL at
    # Capybara's ephemeral server, as a real deployment does for its own host.
    visit '/up'
    server = URI(page.current_url)
    allow(Docuseal).to receive(:default_url_options)
      .and_return(host: server.host, port: server.port, protocol: server.scheme)

    visit "/embed/template_builder/#{token}"
    expect(page).to have_css('template-builder .fields')
    expect(URI(find('template-builder')['data-base-url']).host).to eq(server.host)
    expect(URI(find('template-builder')['data-base-url']).port).to eq(server.port)
    find('a.tab', text: 'Custom', exact_text: true).click
    expect(page).to have_css('.custom-fields .list-field', text: 'loan.number')
    within('.custom-fields') do
      expect(page).not_to have_css('.field-remove-button')
      expect(page).not_to have_css('.field-settings-dropdown')
      expect(page).not_to have_css('[contenteditable="true"]')
      expect(page).to have_css('[draggable="true"]')
    end

    # A palette click arms placement; a click on blank document space creates
    # its default-sized area and autosaves through the token-scoped embed API.
    find('.custom-fields .list-field', text: 'loan.number').click
    first('#pages_container [data-page="0"]').click(x: 180, y: 300)

    page.document.synchronize(10, errors: [RSpec::Expectations::ExpectationNotMetError]) do
      placed = template.reload.fields.find { |field| field['name'] == 'loan.number' }
      expect(placed).to be_present
      expect(placed['type']).to eq('text')
      expect(placed['areas'].sole).to include(
        'attachment_uuid' => template.schema.first['attachment_uuid'], 'page' => 0
      )
      expect(placed['areas'].sole['w']).to be_positive
      expect(placed['areas'].sole['h']).to be_positive
    end

    find('.field-area-container', text: 'loan.number', match: :first).right_click
    expect(page).to have_css('.field-settings-copy')
    find('.field-settings-more').hover
    expect(page).to have_css('.field-settings-draw-new-area')
    expect(page).not_to have_css('.field-settings-save-as-custom-field', visible: :all)
  end
end
