# frozen_string_literal: true

# The public support form (Session 10 Phase B): one email to the support
# mailbox and a receipt, from a page anybody can reach signed in or out.
#
# What this file protects:
#
#   * exactly ONE mail per accepted message, to the support mailbox, with the
#     requester on Reply-To so answering it needs no copy-and-paste;
#   * every FACT about the account in that mail is derived from the session,
#     never from the form — a stranger cannot post "plan: paid";
#   * the three brakes: the per-IP hourly limit, the honeypot (which is told
#     nothing and sends nothing) and Turnstile;
#   * the Turnstile exception to the security policy reaches this page and no
#     other, exactly as it does on sign-up;
#   * nothing is written to the database at all.
RSpec.describe 'Support form', type: :request do
  stash_env 'TURNSTILE_SITE_KEY', 'TURNSTILE_SECRET_KEY', clear: true

  let(:deliveries) { ActionMailer::Base.deliveries }
  let(:message) { 'My signer says the link has expired and I cannot work out how to send it again.' }

  before do
    create(:user, account: create(:account, :operator))
    ENV['TURNSTILE_SITE_KEY'] = 'turnstile-site-key'
    ENV['TURNSTILE_SECRET_KEY'] = 'turnstile-secret-key'
    RateLimit.store.clear
    deliveries.clear
  end

  after { RateLimit.store.clear }

  def doc
    Nokogiri::HTML(response.body)
  end

  def support_params(name: 'Ada Lovelace', email: 'ada@example.com', topic: 'sending', body: nil,
                     token: 'turnstile-token', website: nil)
    { support_request: { name:, email:, topic:, message: body || message },
      'cf-turnstile-response' => token, 'website' => website }.compact
  end

  describe 'GET /support' do
    it 'renders the form to an anonymous visitor with visible labels and every topic' do
      get '/support'

      expect(response).to have_http_status(:ok)
      expect(doc.at_css('h1').text.squish).to eq('Contact support')
      %w[support_request_name support_request_email support_request_topic support_request_message].each do |id|
        expect(doc.at_css("label[for='#{id}']")).to be_present, "no visible label for #{id}"
        expect(doc.at_css("##{id}")).to be_present
      end
      expect(doc.css('#support_request_topic option').pluck('value').compact_blank)
        .to eq(SupportRequest::TOPICS.keys)
      expect(doc.css('#support_request_topic option').map { |o| o.text.squish })
        .to include(*SupportRequest::TOPICS.values)
      expect(doc.at_css('.cf-turnstile')['data-sitekey']).to eq('turnstile-site-key')
    end

    it 'hides the honeypot from sight and from assistive technology, and keeps it out of the tab order' do
      get '/support'

      field = doc.at_css("input[name='#{SupportRequestsController::HONEYPOT_FIELD}']")
      expect(field).to be_present
      expect(field['tabindex']).to eq('-1')
      wrapper = field.ancestors.find { |node| node['aria-hidden'] == 'true' }
      expect(wrapper).to be_present
      expect(wrapper['class']).to include('hidden')
    end

    it 'prefills and freezes the name and the address of a signed-in person' do
      user = create(:user, account: create(:account), first_name: 'Grace', last_name: 'Hopper',
                           email: 'grace@example.com')
      sign_in user

      get '/support'

      expect(doc.at_css('#support_request_name')['value']).to eq(user.full_name)
      expect(doc.at_css('#support_request_name')['readonly']).to be_present
      expect(doc.at_css('#support_request_email')['value']).to eq('grace@example.com')
      expect(doc.at_css('#support_request_email')['readonly']).to be_present
    end

    it 'allows the Turnstile host on this page only, exactly as sign-up does' do
      get '/support'
      policy = response.headers['Content-Security-Policy']

      expect(policy).to match(%r{script-src [^;]*https://challenges\.cloudflare\.com})
      expect(policy).to match(%r{frame-src [^;]*https://challenges\.cloudflare\.com})
      # And nothing else was widened: connect-src and default-src stay 'self'.
      expect(policy).to match(/connect-src 'self'(;|\z)/)
      expect(policy).to match(/default-src 'self'[;\s]/)
      # The widening is those two directives and nothing else.
      expect(policy.scan('challenges.cloudflare.com').size).to eq(2)

      get '/help'
      expect(response.headers['Content-Security-Policy']).not_to include('challenges.cloudflare.com')
    end
  end

  describe 'POST /support' do
    it 'sends exactly one mail to the support mailbox, replying to the requester, and shows the receipt',
       sidekiq: :inline do
      stub_turnstile(success: true)

      expect { post '/support', params: support_params }.to change(deliveries, :count).by(1)

      mail = deliveries.sole
      expect(mail.to).to eq([Docuseal::SUPPORT_EMAIL])
      expect(mail.reply_to).to eq(['ada@example.com'])
      expect(mail.subject).to eq('[EsignCenter support] Sending & signing — Ada Lovelace')
      expect(mail.body.encoded).to include(message)
      expect(mail.body.encoded).to include('Not signed in')
      expect(mail.body.encoded).to include('127.0.0.1')

      expect(response).to have_http_status(:ok)
      expect(doc.at_css('h1').text.squish).to eq('We got your message')
      expect(doc.at_css('main').text).to include('ada@example.com', 'one business day')
    end

    it 'is a platform notice, so the mail carries the product wordmark and the support line', sidekiq: :inline do
      stub_turnstile(success: true)

      post '/support', params: support_params

      body = deliveries.sole.body.encoded
      expect(body).to include(Docuseal.product_name)
      expect(body).to include(Docuseal::SUPPORT_EMAIL)
    end

    it 'carries the account id, kind and plan of a signed-in person, derived from the session', sidekiq: :inline do
      stub_turnstile(success: true)
      account = create(:account, :paid)
      user = create(:user, account:, first_name: 'Grace', last_name: 'Hopper', email: 'grace@example.com')
      sign_in user

      # The form claims to be somebody else on a free plan. It is ignored.
      post '/support', params: support_params(name: 'Not Grace', email: 'attacker@example.com', topic: 'billing')

      mail = deliveries.sole
      expect(mail.reply_to).to eq(['grace@example.com'])
      expect(mail.subject).to eq('[EsignCenter support] Billing — Grace Hopper')
      body = mail.body.encoded
      expect(body).to include(account.id.to_s, account.name, account.account_kind, Plans::PAID, 'grace@example.com')
      expect(body).not_to include('attacker@example.com')
    end

    it 'refuses an invalid address and a message that says nothing, with field errors and no mail' do
      stub_turnstile(success: true)

      expect do
        post '/support', params: support_params(email: 'not-an-address', body: 'help')
      end.not_to change(deliveries, :count)

      expect(response).to have_http_status(:unprocessable_content)
      expect(doc.at_css('#email_error').text).to include('does not look like an email address')
      expect(doc.at_css('#message_error').text).to include('too short')
      expect(doc.at_css('#support_request_email')['aria-invalid']).to eq('true')
      expect(doc.at_css('#support_request_message')['aria-invalid']).to eq('true')
      # What they typed is still there: nobody has to write it twice.
      expect(doc.at_css('#support_request_message').text).to include('help')
    end

    it 'refuses a name over the limit and an unknown topic' do
      stub_turnstile(success: true)

      expect do
        post '/support', params: support_params(name: 'a' * (SupportRequest::NAME_LIMIT + 1), topic: 'nonsense')
      end.not_to change(deliveries, :count)

      expect(response).to have_http_status(:unprocessable_content)
      expect(doc.at_css('main').text).to include('is too long', 'is not one of the choices')
    end

    it 'refuses a failed Turnstile check and sends nothing' do
      stub_turnstile(success: false, error_codes: ['invalid-input-response'])

      expect { post '/support', params: support_params }.not_to change(deliveries, :count)

      expect(response).to have_http_status(:unprocessable_content)
      expect(doc.at_css('main').text).to include(I18n.t('please_complete_the_verification'))
    end

    it 'answers a filled honeypot with the ordinary receipt, byte for byte, and sends nothing' do
      stub_turnstile(success: true)

      post '/support', params: support_params
      honest = Nokogiri::HTML(response.body).at_css('main').to_html

      deliveries.clear

      expect do
        post '/support', params: support_params(website: 'http://spam.example.com')
      end.not_to change(deliveries, :count)

      expect(response).to have_http_status(:ok)
      # The whole page, less the per-render CSRF token the layout mints: a
      # script is told exactly what a person is told.
      expect(Nokogiri::HTML(response.body).at_css('main').to_html).to eq(honest)
    end

    it 'stops the sixth message from one network in an hour, and says so politely' do
      stub_turnstile(success: true)

      SupportRequestsController::REQUESTS_PER_IP_PER_HOUR.times do
        post '/support', params: support_params
        expect(response).to have_http_status(:ok)
      end

      deliveries.clear

      expect { post '/support', params: support_params }.not_to change(deliveries, :count)

      expect(response).to have_http_status(:too_many_requests)
      expect(doc.at_css('main').text).to include('try again a little later')
      expect(doc.css("a[href='mailto:#{Docuseal::SUPPORT_EMAIL}']")).not_to be_empty
    end

    it 'writes nothing to the database' do
      stub_turnstile(success: true)

      expect { post '/support', params: support_params }.not_to change(AbuseFlag, :count)
      expect(defined?(SupportRequest.table_name)).to be_nil
      expect(SupportRequest.ancestors).not_to include(ActiveRecord::Base)
    end
  end

  # An instance with no Cloudflare keys. Sign-up is switched off entirely
  # without them (RegistrationConfigGuard); support must not be, because it is
  # how somebody locked out of their account reaches a person.
  describe 'with no Turnstile keys configured' do
    before do
      ENV.delete('TURNSTILE_SITE_KEY')
      ENV.delete('TURNSTILE_SECRET_KEY')
    end

    it 'draws no widget, loads no third-party script and leaves the policy tight' do
      get '/support'

      expect(response).to have_http_status(:ok)
      expect(doc.css('.cf-turnstile')).to be_empty
      expect(doc.css('script[src]').pluck('src')).to all(start_with('/'))
      expect(response.headers['Content-Security-Policy']).not_to include('challenges.cloudflare.com')
    end

    it 'still delivers a message, with the honeypot and the per-IP limit as the brakes', sidekiq: :inline do
      expect { post '/support', params: support_params(token: nil) }.to change(deliveries, :count).by(1)

      expect(response).to have_http_status(:ok)
      expect(doc.at_css('h1').text.squish).to eq('We got your message')

      deliveries.clear

      expect do
        post '/support', params: support_params(token: nil, website: 'http://spam.example.com')
      end.not_to change(deliveries, :count)
    end
  end

  describe 'the pages that point here' do
    it 'is linked from the marketing footer, the pricing page and the trust page' do
      %w[/ /pricing /trust].each do |path|
        get path

        expect(doc.css("a[href='#{support_path}']")).not_to be_empty, "#{path} does not link to /support"
      end
    end

    it 'keeps the support address visible on /trust, where a security report must not depend on a form' do
      get '/trust'

      expect(doc.css("a[href='mailto:#{Docuseal::SUPPORT_EMAIL}']")).not_to be_empty
    end
  end
end
