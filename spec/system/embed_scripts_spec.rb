# frozen_string_literal: true

RSpec.describe 'Embed scripts', type: :system do
  it 'renders a form iframe and relays completion events' do
    visit '/up'

    page.execute_script <<~JS
      window.embedEvents = [];

      const script = document.createElement('script');
      script.src = '/js/form.js';
      script.onload = () => {
        const form = document.createElement('esigncenter-form');

        form.dataset.src = 'https://docuseal.example.com/s/test-slug';
        form.dataset.email = 'borrower@example.com';
        form.dataset.name = 'Borrower';
        form.dataset.height = '640px';

        form.addEventListener('init', () => window.embedEvents.push({ event: 'init' }));
        form.addEventListener('completed', (event) => {
          window.embedEvents.push({ event: 'completed', detail: event.detail });
        });

        document.body.appendChild(form);
      };

      document.head.appendChild(script);
    JS

    expect(page).to have_css('esigncenter-form iframe', visible: :all)

    iframe_src = page.evaluate_script("document.querySelector('esigncenter-form iframe').src")

    expect(iframe_src).to include('https://docuseal.example.com/s/test-slug')
    expect(iframe_src).to include('email=borrower%40example.com')
    expect(iframe_src).to include('name=Borrower')

    page.execute_script <<~JS
      window.dispatchEvent(new MessageEvent('message', {
        origin: 'https://docuseal.example.com',
        data: {
          source: 'esigncenter-form',
          event: 'completed',
          detail: { submitter: { id: 1, status: 'completed' } }
        }
      }));
    JS

    events = page.evaluate_script('window.embedEvents')

    expect(events).to include({ 'event' => 'init' })
    expect(events).to include(
      'event' => 'completed',
      'detail' => { 'submitter' => { 'id' => 1, 'status' => 'completed' } }
    )
  end

  it 'renders a builder iframe and relays builder events' do
    visit '/up'

    page.execute_script <<~JS
      window.builderEvents = [];

      const script = document.createElement('script');
      script.src = '/js/builder.js';
      script.onload = () => {
        const builder = document.createElement('esigncenter-builder');

        builder.dataset.src = 'https://docuseal.example.com/embed/template_builder/test-token';
        builder.dataset.height = '720px';

        builder.addEventListener('init', () => window.builderEvents.push({ event: 'init' }));
        builder.addEventListener('save', (event) => {
          window.builderEvents.push({ event: 'save', detail: event.detail });
        });

        document.body.appendChild(builder);
      };

      document.head.appendChild(script);
    JS

    expect(page).to have_css('esigncenter-builder iframe', visible: :all)

    iframe_src = page.evaluate_script("document.querySelector('esigncenter-builder iframe').src")

    expect(iframe_src).to include('https://docuseal.example.com/embed/template_builder/test-token')

    page.execute_script <<~JS
      window.dispatchEvent(new MessageEvent('message', {
        origin: 'https://docuseal.example.com',
        data: {
          source: 'esigncenter-builder',
          event: 'save',
          detail: { template: { id: 123, status: 'ready' } }
        }
      }));
    JS

    events = page.evaluate_script('window.builderEvents')

    expect(events).to include({ 'event' => 'init' })
    expect(events).to include(
      'event' => 'save',
      'detail' => { 'template' => { 'id' => 123, 'status' => 'ready' } }
    )
  end

  it 'relays the real embedded builder load event from the iframe' do
    account = create(:account)
    author = create(:user, account:)
    template = create(:template, account:, author:, only_field_types: %w[signature])

    visit '/up'

    origin = URI.parse(page.current_url).origin
    token = template.signed_id(purpose: :embed_builder, expires_in: 2.hours)
    builder_src = "#{origin}/embed/template_builder/#{token}"

    template.update!(
      preferences: {
        'embed_builder' => {
          'origin' => origin,
          'expires_at' => 2.hours.from_now.iso8601
        }
      }
    )

    page.execute_script <<~JS
      window.realBuilderEvents = [];

      const script = document.createElement('script');
      script.src = '/js/builder.js';
      script.onload = () => {
        const builder = document.createElement('esigncenter-builder');

        builder.dataset.src = #{builder_src.to_json};
        builder.dataset.height = '720px';

        builder.addEventListener('load', (event) => {
          window.realBuilderEvents.push({ event: 'load', detail: event.detail });

          if (event.detail?.template?.id === #{template.id}) {
            document.body.dataset.realBuilderLoaded = 'true';
          }
        });

        document.body.appendChild(builder);
      };

      document.head.appendChild(script);
    JS

    expect(page).to have_css('esigncenter-builder iframe', visible: :all)
    expect(page).to have_css('body[data-real-builder-loaded="true"]', visible: :all)

    events = page.evaluate_script('window.realBuilderEvents')

    expect(events).to include(
      'event' => 'load',
      'detail' => hash_including(
        'template' => hash_including(
          'id' => template.id,
          'status' => 'ready'
        )
      )
    )
  end
end
