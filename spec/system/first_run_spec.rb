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

  # Review 10 (A-F3). Steps 2 and 3 used to link to
  # `templates.active.order(:id).first`, which on a seeded account is always
  # one of the four starters — never the document the person had just
  # uploaded — and to the dashboard they were already on when the account held
  # no template at all.
  context 'when the steps are followed' do
    def step_href(step)
      URI.parse(page.find(%([data-first-run-step="#{step}"]))['href'])
    end

    it 'sends the next two steps to the document this person chose, not to a seeded starter' do
      seed_starter_template!
      create(:template, account:, author: user, only_field_types: %w[text], name: 'An older contract')
      own = create(:template, account:, author: user, only_field_types: %w[text], name: 'Our supplier contract')

      visit root_path

      expect(page).to have_css('[data-first-run-step="choose"][data-done="true"]')
      expect(step_href('signer').path).to eq(template_path(own))
      expect(step_href('send').path).to eq(template_path(own))
    end

    # The ORDER BY expression is the fix, not `id: :desc`: joining another
    # team moves the starters across with FRESH ids, so the account's own
    # document stops being the newest row. Ranked by id alone, steps 2 and 3
    # would go straight back to a starter (review 10, loop 2).
    it 'still sends them to their own document when a starter arrives after it' do
      own = create(:template, account:, author: user, only_field_types: %w[text], name: 'Our supplier contract')
      starter = seed_starter_template!

      expect(starter.id).to be > own.id

      visit root_path

      expect(page).to have_css('[data-first-run-step="choose"][data-done="true"]')
      expect(step_href('signer').path).to eq(template_path(own))
      expect(step_href('send').path).to eq(template_path(own))
    end

    # Picking a starter is the other half of "upload/pick a template", so a
    # starter is the right destination when it is all the account holds.
    it 'sends them to a starter template when that is all the account holds' do
      starter = seed_starter_template!

      visit root_path

      expect(step_href('signer').path).to eq(template_path(starter))
      expect(step_href('send').path).to eq(template_path(starter))
    end

    # A failed StarterTemplatesJob leaves an account with nothing to send, and
    # the three steps must still go somewhere useful — the upload button, not
    # a reload of this page.
    it 'sends them to the upload button when the account holds no template at all' do
      visit root_path

      expect(page).to have_css('[data-first-run-checklist]')

      %w[choose signer send].each do |step|
        expect(step_href(step).path).to eq(templates_path)
        expect(step_href(step).fragment).to eq('templates_upload_button')
      end
    end
  end

  # --- review 1 regressions --------------------------------------------------

  context 'when the app tour would draw its welcome card too' do
    # Two onboarding widgets making the same offer, 200 pixels apart, on a
    # brand-new account's first screen. The checklist supersedes the tour's
    # welcome card; the tour itself is untouched.
    it 'takes the app tour\'s welcome card off the dashboard while it is showing' do
      seed_starter_template!

      visit root_path

      expect(page).to have_css('[data-first-run-checklist]')
      expect(page).to have_no_css('#app_tour_manager')
      expect(page).to have_no_content('Start tour')
    end

    # W2 (session 10 staging walk). The checklist retires itself the moment
    # the third step is ticked, and the tour's welcome card used to take the
    # space back: the account had just sent its first document and the
    # dashboard offered it a beginner's tour. Superseded means superseded.
    it 'does not put the welcome card back when the checklist completes' do
      sent_submission!(seed_starter_template!)

      visit root_path

      expect(page).to have_no_css('[data-first-run-checklist]')
      expect(page).to have_no_css('#app_tour_manager')
      expect(page).to have_no_content('Start tour')
    end

    # Same for the other way the card goes away: somebody who has put the
    # checklist away has said they do not want to be walked through this.
    it 'does not put the welcome card back when the checklist is dismissed' do
      seed_starter_template!

      visit root_path
      find('[data-first-run-dismiss]').click

      expect(page).to have_no_css('[data-first-run-checklist]')

      visit root_path

      expect(page).to have_no_css('#app_tour_manager')
    end

    # And the tour's welcome card is not gone from the product: an account the
    # checklist never applies to still gets it.
    it 'still welcomes an account the checklist does not apply to' do
      account.update!(created_at: 2.months.ago)
      create(:template, account:, author: user, only_field_types: %w[text], name: 'Our supplier contract')

      visit root_path

      expect(page).to have_no_css('[data-first-run-checklist]')
      expect(page).to have_css('#app_tour_manager')
    end
  end

  context 'when the page is read out rather than looked at' do
    # Colour, a strikethrough and an unlabelled tick say nothing to assistive
    # technology, and "1 of 3 done" never says WHICH one (review 1 M2).
    it 'names the done state of every step in words' do
      own = create(:template, account:, author: user, only_field_types: %w[text], name: 'Our supplier contract')
      create(:submission, :with_submitters, template: own, created_by_user: user)

      visit root_path

      expect(page).to have_css('[data-first-run-step="choose"][data-done="true"]')
      done = page.all('.sr-only', visible: :all).map(&:text)
      expect(done.count { |text| text.include?(I18n.t('first_run_step_done')) }).to be >= 2
      expect(done.count { |text| text.include?(I18n.t('first_run_step_not_done')) }).to be >= 1

      # The numbered badge is decoration once the status is in the text.
      expect(page).to have_css('[data-first-run-step="send"] span[aria-hidden="true"]', visible: :all)
      expect(page).to have_css("ol[aria-label='#{I18n.t('first_run_checklist_title')}']")
    end
  end

  context 'when the first document has been signed' do
    # The banner IS shared/_upgrade_cta with its own words and a dismiss ×
    # (review 1 M1), so this is where it is looked at: the screenshots below
    # are the visual pass on that card.
    before do
      account.account_configs.create!(key: AccountConfig::FIRST_COMPLETION_UPGRADE_PROMPT_KEY,
                                      value: { 'shown_at' => Time.current.utc.iso8601 })
    end

    it 'draws the shared upgrade card at phone and desktop widths' do
      { 390 => 844, 1440 => 900 }.each do |width, height|
        page.driver.resize(width, height)

        visit root_path

        expect(page).to have_css('[data-first-completion-prompt] [data-upgrade-cta]')
        expect(page).to have_content(I18n.t('first_completion_prompt_title'))
        expect(page.evaluate_script('document.documentElement.scrollWidth <= document.documentElement.clientWidth'))
          .to be(true), "the upgrade nudge scrolls sideways at #{width}px"

        page.driver.browser.screenshot(path: screenshot_dir.join("completion-prompt-#{width}.png").to_s, full: true)
      end
    end

    it 'puts itself away for the whole account when it is dismissed' do
      visit root_path

      find('[data-first-completion-dismiss]').click

      expect(page).to have_no_css('[data-first-completion-prompt]')

      visit root_path

      expect(page).to have_no_css('[data-first-completion-prompt]')
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
