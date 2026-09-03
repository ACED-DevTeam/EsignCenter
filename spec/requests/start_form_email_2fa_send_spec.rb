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
end
