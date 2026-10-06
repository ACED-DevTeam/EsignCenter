# frozen_string_literal: true

# The anonymous "email me a code" door behind a share link's email 2FA
# (POST /start_form_email_2fa_send, which the "Resend" button uses). It mails
# an address nobody has confirmed, from the platform's own sending account,
# and writes no row for any quota to count — so it is guarded three ways:
# exactly one well-formed recipient, an hourly ceiling on the account that a
# pool of proxies cannot walk around, and no code at all for a link that never
# asked for one.
RSpec.describe 'Share-link email-2FA verification code', type: :request do
  let(:account) { create(:account) }
  let(:user) { create(:user, account:) }
  let(:template) { create(:template, account:, author: user, shared_link: true) }

  before do
    template.update!(preferences: template.preferences.merge('shared_link_2fa' => true))
    RateLimit.store.clear
  end

  after { RateLimit.store.clear }

  def send_code(email)
    post '/start_form_email_2fa_send', params: { slug: template.slug, submitter: { email: } }
  end

  def recipients
    ActionMailer::Base.deliveries.flat_map { |message| Array(message.to) }
  end

  # The seam both doors share, driven straight at it from a hundred different
  # addresses so the per-IP window never fires: what fills up is the account's
  # own hourly ceiling.
  def fill_account_ceiling!
    Quotas::Limits::SHARED_LINK_CODES_PER_ACCOUNT_PER_HOUR.times do |index|
      submitter = template.submissions.new(account_id: account.id)
                          .submitters.new(email: "signer#{index}@example.com", account_id: account.id)

      Submitters.send_shared_link_email_verification_code(
        submitter,
        request: ActionDispatch::TestRequest.create('REMOTE_ADDR' => "10.0.#{index / 256}.#{index % 256}")
      )
    end
  end

  # ActionMailer's `mail(to:)` splits a comma-separated string into as many
  # recipients as it holds, and this submitter is never saved, so no model
  # validation has ever looked at the address. One POST would otherwise mail a
  # list of strangers from our own sending account.
  it 'mails nobody at all when a comma-separated list is posted', sidekiq: :inline do
    expect { send_code('a@example.com, b@example.com, c@example.com') }
      .not_to change(ActionMailer::Base.deliveries, :count)

    expect(recipients).to be_empty
    expect(Submission.count).to eq(0)
    expect(Submitter.count).to eq(0)
    expect(response.location).to include("/d/#{template.slug}")
    expect(flash[:alert]).to eq('Email is invalid')
  end

  it 'refuses header injection and every other second address', sidekiq: :inline do
    ["signer@example.com\nbcc: victim@example.com",
     "signer@example.com\r\nbcc: victim@example.com",
     'signer@example.com; victim@example.com',
     'signer@example.com victim@example.com',
     '"Signer" <signer@example.com>, victim@example.com'].each do |address|
      expect { send_code(address) }.not_to change(ActionMailer::Base.deliveries, :count)

      expect(recipients).to be_empty
      expect(flash[:alert]).to eq('Email is invalid')
    end

    # The address is checked before either counter is spent, so a run of
    # refusals never eats the two-per-45-seconds an honest visitor has.
    expect { send_code('signer@example.com') }.to change(ActionMailer::Base.deliveries, :count).by(1)

    expect(recipients).to eq(['signer@example.com'])
  end

  it 'still emails one honest address its code', sidekiq: :inline do
    expect { send_code('signer@example.com') }.to change(ActionMailer::Base.deliveries, :count).by(1)

    message = ActionMailer::Base.deliveries.last

    expect(message.to).to eq(['signer@example.com'])
    expect(message.body.encoded[%r{<b>(.*?)</b>}, 1]).to be_present
    expect(response.location).to include("/d/#{template.slug}")
    expect(flash[:alert]).to be_nil
  end

  # Per-IP alone is no defence: the addresses are rented, the account is not.
  it 'refuses the send past the account\'s hourly ceiling, in the wording that already exists' do
    fill_account_ceiling!

    expect { send_code('signer@example.com') }.not_to change(ActionMailer::Base.deliveries, :count)

    expect(response.location).to include("/d/#{template.slug}")
    expect(flash[:alert]).to eq(I18n.t('too_many_attempts'))
  end

  # The endpoint answers for any template slug, so it has to mirror the one
  # branch of the start form that sends a code: no email 2FA on the link, no
  # email out of it.
  it 'sends no code for a link that does not ask for email verification', sidekiq: :inline do
    template.update!(preferences: template.preferences.except('shared_link_2fa'))

    expect { send_code('signer@example.com') }.not_to change(ActionMailer::Base.deliveries, :count)

    expect(response).to redirect_to("/d/#{template.slug}")
    expect(Submitter.count).to eq(0)
  end

  # Switching sharing off, or archiving the template, is how an owner revokes a
  # link — and the URL outlives that decision in inboxes and browser history.
  # The start form gives a revoked slug the form page's own answer (private or
  # not-found when it is no longer shared, the form itself once archived) and
  # never work done on the account's behalf; this door has to agree, or
  # revocation would leave the platform still mailing strangers on request.
  describe 'a revoked link' do
    it 'sends no code once sharing is switched off, and answers as the start form does', sidekiq: :inline do
      template.update!(shared_link: false)

      expect { send_code('signer@example.com') }.not_to change(ActionMailer::Base.deliveries, :count)

      expect(recipients).to be_empty
      expect(Submitter.count).to eq(0)
      expect(response).to redirect_to("/d/#{template.slug}")

      # And that is the start form's answer for a template nobody shared and
      # this visitor cannot read: not found, never a hint that it exists.
      expect { follow_redirect! }.to raise_error(ActionController::RoutingError)
    end

    it 'sends no code once the template is archived, and answers as the start form does', sidekiq: :inline do
      template.update!(archived_at: Time.current)

      expect { send_code('signer@example.com') }.not_to change(ActionMailer::Base.deliveries, :count)

      expect(recipients).to be_empty
      expect(Submitter.count).to eq(0)
      expect(response).to redirect_to("/d/#{template.slug}")

      follow_redirect!

      expect(response).to have_http_status(:ok)
    end

    # The control for the two above: an honest link is untouched by the check.
    it 'still emails the code for a shared, unarchived link that asks for one', sidekiq: :inline do
      expect { send_code('signer@example.com') }.to change(ActionMailer::Base.deliveries, :count).by(1)

      expect(recipients).to eq(['signer@example.com'])
      expect(response.location).to include("/d/#{template.slug}")
      expect(flash[:alert]).to be_nil
    end
  end

  # A paused account's business — which limit closed the link, the number it
  # is, the date it resets — belongs to the account, not to whoever holds the
  # slug. The paused page has always drawn that line (StartFormController's
  # render_paused fills in the detail only for the sender); this endpoint
  # refuses in the same two voices.
  describe "while the account's link is paused" do
    let(:detailed) { Quotas.pause_message(account, :completions) }

    # The operator's own tool, set to zero: the link is closed on the first
    # completion asked of it, with a real reason and a real reset date.
    before { AccountLimitOverride.create!(account:, completions_per_month: 0) }

    it 'refuses an anonymous poster in the generic wording, naming no limit', sidekiq: :inline do
      expect { send_code('signer@example.com') }.not_to change(ActionMailer::Base.deliveries, :count)

      expect(recipients).to be_empty
      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body).to eq('error' => I18n.t('form_not_accepting_responses'))

      expect(response.body).not_to include(detailed)
      expect(response.body).not_to include(Quotas.resets_at.strftime('%Y-%m-%d'))
      expect(response.body).not_to include('completion')
    end

    it "still tells the account's own signed-in user what closed the link", sidekiq: :inline do
      sign_in(user)

      expect { send_code('signer@example.com') }.not_to change(ActionMailer::Base.deliveries, :count)

      expect(response).to have_http_status(:unprocessable_content)
      expect(response.parsed_body).to eq('error' => detailed)
    end
  end
end
