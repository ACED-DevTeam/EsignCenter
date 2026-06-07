# frozen_string_literal: true

RSpec.describe 'Embed scripts', type: :system do
  it 'renders a form iframe and relays completion events' do
    visit '/up'

    page.execute_script <<~JS
      window.embedEvents = [];

      const script = document.createElement('script');
      script.src = '/js/form.js';
      script.onload = () => {
        const form = document.createElement('docuseal-form');

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

    expect(page).to have_css('docuseal-form iframe', visible: :all)

    iframe_src = page.evaluate_script("document.querySelector('docuseal-form iframe').src")

    expect(iframe_src).to include('https://docuseal.example.com/s/test-slug')
    expect(iframe_src).to include('email=borrower%40example.com')
    expect(iframe_src).to include('name=Borrower')

    page.execute_script <<~JS
      window.dispatchEvent(new MessageEvent('message', {
        origin: 'https://docuseal.example.com',
        data: {
          source: 'docuseal-form',
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
end
