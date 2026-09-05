# frozen_string_literal: true

# Settings in a real browser (Session 9 Phase D): the pages behind the gear
# have to be usable on a phone, not merely reachable from one.
#
# Two things were wrong and both are proved here. The settings navigation used
# to stack above the content, so on a 390px screen the page you actually asked
# for started roughly 680px down — a screen and a half of scrolling before the
# first heading. And /settings/account scrolled sideways by 76px, pushed there
# by daisyUI's tooltip bubbles, which sit in the layout at up to 20rem wide
# even while they are faded out.
#
# The support-access card is the desktop half of the same story: six table
# columns never fitted the 576px settings column, so "Actions" and "Reason"
# were cut off at any window size, 1440 included.
RSpec.describe 'Settings on a phone' do
  let!(:account) { create(:account) }
  let!(:user) { create(:user, account:) }

  # Every settings page, so a regression anywhere in the set is caught, not
  # just on the three the screenshots cover.
  pages = {
    'profile' => '/settings/profile',
    'users' => '/settings/users',
    'account' => '/settings/account',
    'api' => '/settings/api',
    'webhooks' => '/settings/webhooks',
    'personalization' => '/settings/personalization',
    'email' => '/settings/email',
    'esign' => '/settings/esign',
    'notifications' => '/settings/notifications',
    'usage' => '/settings/usage',
    'export' => '/settings/export'
  }

  before do
    FileUtils.mkdir_p(screenshot_dir)
    sign_in(user)
  end

  def screenshot_dir
    Rails.root.join('tmp/screenshots')
  end

  # The three pages the phone screenshots cover; the rest are measured only.
  def screenshot?(name)
    %w[profile users account].include?(name)
  end

  def overflow
    page.evaluate_script(<<~JS)
      (function () {
        var el = document.scrollingElement || document.documentElement;
        return el.scrollWidth - el.clientWidth;
      })()
    JS
  end

  # Where the page's own content starts. The settings navigation is not it:
  # the first heading inside the content column is what the reader came for.
  def first_heading_top
    page.evaluate_script(<<~JS)
      (function () {
        var h = document.querySelector('h1, h2');
        return h ? Math.round(h.getBoundingClientRect().top) : -1;
      })()
    JS
  end

  describe 'at 390x844' do
    before { page.driver.resize(390, 844) }

    pages.each do |name, path|
      it "renders #{path} without sideways scrolling, with its content near the top" do
        visit path

        expect(page).to have_css('#account_settings_menu')
        expect(overflow).to be <= 0, "#{path} scrolls sideways by #{overflow}px at 390"
        expect(first_heading_top).to be_between(0, 220),
                                     "#{path} starts its content #{first_heading_top}px down"

        page.driver.browser.screenshot(path: screenshot_dir.join("settings-#{name}-390.png").to_s) if screenshot?(name)
      end
    end

    it 'keeps the settings navigation on one horizontal strip' do
      visit '/settings/profile'

      # Every link in the strip sits on the same row: the menu scrolls
      # sideways rather than stacking, which is the whole point of the change.
      tops = page.evaluate_script(<<~JS)
        Array.from(document.querySelectorAll('#account_settings_menu a'))
             .filter(function (a) { return a.offsetParent !== null })
             .map(function (a) { return Math.round(a.getBoundingClientRect().top) })
      JS

      expect(tops).not_to be_empty
      expect(tops.uniq.size).to eq(1)
    end
  end

  describe 'at 1440x900' do
    # One finished support session, so the card has something to draw.
    let!(:started) do
      OperatorEvent.create!(account:, action: 'impersonation.start',
                            reason: 'Customer asked us to look at a stuck signing request that would not send.',
                            details: { 'user_email' => user.email, 'mode' => 'read_only' })
    end

    let!(:ended) do
      OperatorEvent.create!(account:, action: 'impersonation.end',
                            details: { 'start_event_id' => started.id, 'duration_seconds' => 420,
                                       'action_count' => 2, 'refused_count' => 1 })
    end

    before { page.driver.resize(1440, 900) }

    it 'shows every column of the support-access card inside the window' do
      visit '/settings/account'

      expect(page).to have_css('[data-support-access-card]')
      expect(page).to have_css("[data-support-access-changes='#{started.id}']")

      right_edge = page.evaluate_script(<<~JS)
        (function () {
          var el = document.querySelector('[data-support-access-changes]');
          return Math.ceil(el.getBoundingClientRect().right);
        })()
      JS

      expect(right_edge).to be <= page.evaluate_script('window.innerWidth')
      expect(page).to have_content(I18n.t('support_access_changes'))
      expect(page).to have_content(I18n.t('support_access_reason'))
      # The end row's own numbers, which is what makes the card worth reading.
      expect(page).to have_content(
        ActionController::Base.helpers.distance_of_time_in_words(ended.details['duration_seconds'].seconds)
      )
      expect(page).to have_content(I18n.t('support_access_changes_summary', count: 2))
      expect(overflow).to be <= 0

      # Full height: the card sits at the bottom of a long page, and a
      # viewport-sized shot of the top of it would prove nothing.
      page.driver.browser.screenshot(path: screenshot_dir.join('settings-support-access-1440.png').to_s,
                                     full: true)
    end

    # The app shell from a keyboard (Session 9, D2/8). daisyUI's dropdown opens
    # on focus-within, which only works while the trigger is focusable, and the
    # focus ring that says where you are is a rule this session added.
    it 'opens the navbar account menu from the keyboard, with a visible focus ring' do
      visit '/settings/profile'

      page.execute_script("document.querySelector('.dropdown > label[tabindex]').focus()")

      expect(page).to have_css('.dropdown-content', visible: :visible)
      within('.dropdown-content') { expect(page).to have_button(I18n.t('sign_out')) }

      # A ring, not the browser's near-invisible default.
      outline = page.evaluate_script(<<~JS)
        (function () {
          var el = document.querySelector('#account_settings_menu a');
          el.focus();
          var cs = getComputedStyle(el);
          return cs.outlineStyle + ' ' + cs.outlineWidth;
        })()
      JS

      expect(outline).to eq('solid 3px')
    end

    it 'closes a settings modal with the Escape key' do
      visit '/settings/account'

      find('[data-delete-account-button]').click

      expect(page).to have_css('[data-delete-account-modal]', visible: :visible)

      page.driver.browser.page.keyboard.type(:escape)

      expect(page).to have_no_css('[data-delete-account-modal]', visible: :visible)
    end
  end
end
