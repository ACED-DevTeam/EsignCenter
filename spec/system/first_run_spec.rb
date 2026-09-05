# frozen_string_literal: true

# The first-run checklist in a real browser (Session 10 A1/A2): a brand-new
# customer account is told the three things that get a document signed, the
# steps tick themselves off as the work is really done, the card can be put
# away for good, and it never appears where it does not belong.
RSpec.describe 'First-run checklist' do
  let(:account) { create(:account) }
  let!(:user) { create(:user, account:) }

  before do
    FileUtils.mkdir_p(screenshot_dir)
    sign_in(user)
  end

  def screenshot_dir
    Rails.root.join('tmp/screenshots')
  end

  # What a freshly seeded account holds: four templates that nobody chose.
  def seed_starter_template!
    create(:template, account:, author: user, only_field_types: %w[text],
                      name: 'Mutual Non-Disclosure Agreement', preferences: { 'starter' => true })
  end

  def sent_submission!(template)
    submission = create(:submission, :with_submitters, template:, created_by_user: user)

    submission.submitters.each { |submitter| submitter.update!(sent_at: Time.current) }

    submission
  end

  context 'when the account is brand new' do
    before { seed_starter_template! }

    it 'offers all three steps, none of them done, on both dashboards' do
      visit root_path

      expect(page).to have_css('[data-first-run-checklist]')
      expect(page).to have_content('Get your first document signed')
      expect(page).to have_content('0 of 3 done')
      expect(page).to have_css('[data-first-run-step="choose"][data-done="false"]')
      expect(page).to have_css('[data-first-run-step="signer"][data-done="false"]')
      expect(page).to have_css('[data-first-run-step="send"][data-done="false"]')

      visit submissions_path

      expect(page).to have_css('[data-first-run-checklist]')
      expect(page).to have_content('0 of 3 done')
    end

    it 'renders at phone and desktop widths without sideways scrolling' do
      { 390 => 844, 1440 => 900 }.each do |width, height|
        page.driver.resize(width, height)

        visit root_path

        expect(page).to have_css('[data-first-run-checklist]')
        expect(page.evaluate_script('document.documentElement.scrollWidth <= document.documentElement.clientWidth'))
          .to be(true), "the checklist scrolls sideways at #{width}px"

        page.driver.browser.screenshot(path: screenshot_dir.join("first-run-#{width}.png").to_s, full: true)
      end
    end

    it 'puts the card away for good when it is dismissed' do
      visit root_path

      expect(page).to have_css('[data-first-run-checklist]')

      find('[data-first-run-dismiss]').click

      expect(page).to have_no_css('[data-first-run-checklist]')
      expect(user.user_configs.find_by(key: UserConfig::SHOW_FIRST_RUN_CHECKLIST).value).to be(false)

      visit root_path

      expect(page).to have_no_css('[data-first-run-checklist]')
    end
  end

  context 'when the work has been started' do
    it 'ticks the steps off as the real rows appear' do
      starter = seed_starter_template!

      visit root_path
      expect(page).to have_content('0 of 3 done')

      # A document of their own: an upload, not one of ours.
      own = create(:template, account:, author: user, only_field_types: %w[text], name: 'Our supplier contract')

      visit root_path
      expect(page).to have_content('1 of 3 done')
      expect(page).to have_css('[data-first-run-step="choose"][data-done="true"]')
      expect(page).to have_css('[data-first-run-step="signer"][data-done="false"]')

      # A signer, but nothing out of the door yet.
      submission = create(:submission, :with_submitters, template: own, created_by_user: user)

      visit root_path
      expect(page).to have_content('2 of 3 done')
      expect(page).to have_css('[data-first-run-step="signer"][data-done="true"]')
      expect(page).to have_css('[data-first-run-step="send"][data-done="false"]')

      # Sent: the card has nothing left to say and takes itself away.
      submission.submitters.each { |submitter| submitter.update!(sent_at: Time.current) }

      visit root_path
      expect(page).to have_no_css('[data-first-run-checklist]')
      expect(page).to have_content(starter.name)
    end

    # Somebody who sent one of the starter templates straight off has chosen a
    # document — the first step must not sit there unticked telling them
    # otherwise.
    it 'counts sending a starter template as choosing a document' do
      sent_submission!(seed_starter_template!)

      visit root_path

      expect(page).to have_no_css('[data-first-run-checklist]')
    end
  end

  context 'when the card does not belong' do
    it 'stays away from an internal account' do
      internal = create(:account, :internal)

      sign_in(create(:user, account: internal))

      visit root_path

      expect(page).to have_no_css('[data-first-run-checklist]')
    end

    it 'stays away from an account older than the first-run window' do
      seed_starter_template!
      account.update!(created_at: 31.days.ago)

      visit root_path

      expect(page).to have_no_css('[data-first-run-checklist]')
    end

    it 'stays away from somebody who may not create templates' do
      seed_starter_template!
      user.update!(read_only_at: Time.current)

      visit root_path

      expect(page).to have_no_css('[data-first-run-checklist]')
    end
  end
end
