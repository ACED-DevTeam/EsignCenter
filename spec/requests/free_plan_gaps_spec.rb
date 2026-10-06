# frozen_string_literal: true

# Two doors that used to walk around a free-plan cap (launch security review,
# finding 4): unarchiving a document skipped the open-documents cap, and a
# saved signature or initials image skipped the storage cap.
RSpec.describe 'Free-plan caps on unarchive and on saved signatures', type: :request do
  let(:free_account) { create(:account) }
  let(:paid_account) { create(:account, :paid) }
  let(:admins) { {} }
  let(:in_flight_alert) do
    I18n.t('quota_reached_in_flight', limit: Quotas::Limits::FREE_IN_FLIGHT,
                                      date: Quotas.resets_at.strftime('%Y-%m-%d'))
  end

  before { platform_certificate! }

  def admin_for(account)
    admins[account.id] ||= create(:user, account:)
  end

  def send_one(account, template:)
    Submissions.create_from_emails(template:, user: admin_for(account), source: :invite, mark_as_sent: true,
                                   emails: "signer-#{SecureRandom.hex(4)}@example.com").sole
  end

  def text_template_for(account)
    create(:template, account:, author: admin_for(account), only_field_types: %w[text])
  end

  describe 'POST /submissions/:id/unarchive' do
    it 'refuses to put an archived document back in flight when a free account already has 10 open' do
      template = text_template_for(free_account)
      archived = send_one(free_account, template:)
      archived.update!(archived_at: Time.current)
      Array.new(Quotas::Limits::FREE_IN_FLIGHT) { send_one(free_account, template:) }
      sign_in(admin_for(free_account))

      post submission_unarchive_index_path(archived)

      expect(response).to redirect_to(submission_path(archived))
      expect(flash[:alert]).to eq(in_flight_alert)
      expect(archived.reload.archived_at).to be_present
      expect(Quotas.in_flight(free_account)).to eq(Quotas::Limits::FREE_IN_FLIGHT)
    end

    it 'unarchives when the free account has room, and a document that takes no slot even when full' do
      template = text_template_for(free_account)
      archived = send_one(free_account, template:)
      archived.update!(archived_at: Time.current)
      sign_in(admin_for(free_account))

      post submission_unarchive_index_path(archived)

      expect(flash[:notice]).to eq(I18n.t('submission_has_been_unarchived'))
      expect(archived.reload.archived_at).to be_nil

      declined = send_one(free_account, template:)
      declined.submitters.first.update!(declined_at: Time.current)
      declined.update!(archived_at: Time.current)
      Array.new(Quotas::Limits::FREE_IN_FLIGHT - 1) { send_one(free_account, template:) }

      post submission_unarchive_index_path(declined)

      expect(flash[:notice]).to eq(I18n.t('submission_has_been_unarchived'))
      expect(declined.reload.archived_at).to be_nil
    end

    it 'never refuses a paid account, whose open-documents number is a review flag' do
      template = text_template_for(paid_account)
      archived = send_one(paid_account, template:)
      archived.update!(archived_at: Time.current)
      AccountLimitOverride.create!(account: paid_account, in_flight_per_seat: 0)
      sign_in(admin_for(paid_account))

      post submission_unarchive_index_path(archived)

      expect(flash[:notice]).to eq(I18n.t('submission_has_been_unarchived'))
      expect(archived.reload.archived_at).to be_nil
      expect(AbuseFlag.where(account: paid_account, kind: 'in_flight')).to exist
    end
  end

  describe 'saving a signature or initials image' do
    let(:image_path) { Rails.root.join('spec/fixtures/sample-image.png') }

    def upload
      Rack::Test::UploadedFile.new(image_path, 'image/png')
    end

    def cap!(account, room:)
      AccountLimitOverride.create!(account:, storage_bytes: Quotas::Storage.bytes_used(account) + room)
    end

    %w[signature initials].each do |kind|
      it "refuses a saved #{kind} image that would take a full account past its storage cap" do
        user = admin_for(free_account)
        cap!(free_account, room: image_path.size - 1)
        sign_in(user)
        path = kind == 'signature' ? user_signature_path : user_initials_path

        expect { patch path, params: { file: upload } }.not_to change(ActiveStorage::Blob, :count)

        expect(response).to redirect_to(settings_profile_index_path)
        expect(flash[:alert]).to eq(Quotas::Storage.message_for(used: Quotas::Storage.bytes_used(free_account),
                                                                limit: Quotas::Storage.limit_bytes(free_account)))
        expect(UserConfig.where(user:)).not_to exist
      end

      it "saves a #{kind} image when it fits" do
        user = admin_for(free_account)
        cap!(free_account, room: image_path.size)
        sign_in(user)
        path = kind == 'signature' ? user_signature_path : user_initials_path

        expect { patch path, params: { file: upload } }.to change(ActiveStorage::Blob, :count).by(1)

        expect(flash[:alert]).to be_nil
        expect(UserConfig.where(user:)).to exist
      end
    end
  end
end
