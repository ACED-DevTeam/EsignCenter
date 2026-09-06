# frozen_string_literal: true

# The marketing pages in a real browser (Session 9 Phase B, extended with the
# help centre and the support form in Session 10 Phase B): nothing scrolls
# sideways on a phone or a desktop, the phone menu works from the keyboard,
# the reduced-motion rule ships, and a screenshot of every page at both widths
# lands in tmp/screenshots for the visual pass.
RSpec.describe 'Marketing pages in the browser' do
  pages = { 'landing' => '/', 'pricing' => '/pricing', 'trust' => '/trust',
            'help' => '/help', 'help-article' => '/help/free-plan-limits', 'support' => '/support' }
  widths = { 390 => 844, 1440 => 900 }

  before do
    create(:user, account: create(:account, :operator))
    FileUtils.mkdir_p(screenshot_dir)
  end

  def screenshot_dir
    Rails.root.join('tmp/screenshots')
  end

  def keyboard
    page.driver.browser.page.keyboard
  end

  def no_horizontal_overflow?
    page.evaluate_script('document.documentElement.scrollWidth <= document.documentElement.clientWidth')
  end

  # Two real animation frames, waited for rather than assumed. A bare round
  # trip is not enough: an IntersectionObserver delivers its entries on a
  # frame, and the reveal listener is throttled to one, so a scroll whose frame
  # never ran leaves a section at opacity 0 and nothing later fires to fix it —
  # the page has stopped scrolling. This is what made the sweep depend on how
  # tall the page happened to be.
  def next_frame
    page.evaluate_async_script(<<~JS)
      const done = arguments[0]
      requestAnimationFrame(() => requestAnimationFrame(() => done(null)))
    JS
  end

  # Reveal-on-scroll sections stay at opacity 0 until they intersect, so the
  # page is scrolled through a viewport at a time, the way a reader would,
  # before a full-height screenshot is taken. `visible: :all` matters: an
  # opacity-0 section is exactly the invisible node a visible-only query
  # would skip over.
  def reveal_everything
    steps = page.evaluate_script('Math.ceil(document.body.scrollHeight / window.innerHeight)')
    (0..steps).each do |step|
      page.execute_script("window.scrollTo(0, #{step} * window.innerHeight)")
      next_frame # the observer and the scroll listener both run on a frame
    end
    expect(page).to have_no_css('.mk-reveal:not(.mk-revealed)', visible: :all, wait: 5)
    page.execute_script('window.scrollTo(0, 0)')
    wait_for_hero_to_settle
  end

  # The hero redraws its signature and pops its seal in once revealed (about
  # 2.3 s); the screenshot is of the finished picture, not a frame of it.
  def wait_for_hero_to_settle
    return unless page.has_css?('.mk-hero-sign', wait: 0)

    page.document.synchronize(6) do
      raise Capybara::ElementNotFound, 'hero still animating' unless hero_settled?
    end
  end

  def hero_settled?
    page.evaluate_script(<<~JS)
      (() => {
        const sign = document.querySelector('.mk-hero-sign')
        const seal = document.querySelector('.mk-hero-seal')
        return parseFloat(getComputedStyle(sign).strokeDashoffset) === 0 && getComputedStyle(seal).opacity === '1'
      })()
    JS
  end

  # And the case the observer must handle itself: a reader who jumps straight
  # to the bottom must not leave the middle of the page blank.
  it 'reveals sections that were jumped past' do
    page.driver.resize(390, 844)
    visit '/'

    expect(page).to have_css('.mk-reveal:not(.mk-revealed)', visible: :all)
    page.execute_script('window.scrollTo(0, document.body.scrollHeight)')
    expect(page).to have_no_css('.mk-reveal:not(.mk-revealed)', visible: :all, wait: 5)
  end

  widths.each do |width, height|
    describe "at #{width}x#{height}" do
      before { page.driver.resize(width, height) }

      pages.each do |name, path|
        it "renders #{path} without sideways scrolling and saves a screenshot" do
          visit path

          expect(page).to have_css('main#main')
          expect(no_horizontal_overflow?).to be(true), "#{path} scrolls sideways at #{width}px"

          reveal_everything
          expect(no_horizontal_overflow?).to be(true)

          # Ferrum's own screenshot call: the CTO's visual pass reads these files.
          page.driver.browser.screenshot(path: screenshot_dir.join("#{name}-#{width}.png").to_s, full: true)
        end
      end
    end
  end

  # --- review 1 regression (Codex 1) -----------------------------------------

  # /support widens its security policy for the Turnstile widget. A Turbo visit
  # paints it inside the previous document, which still carries the ordinary
  # `script-src 'self'`, so the widget can never load and the form can never be
  # submitted. Reaching it from the footer has to be a REAL navigation.
  it 'reaches the support form from a marketing link as a full page load' do
    visit '/pricing'

    # A mark on the window object of THIS document. A Turbo visit keeps the
    # document (and the mark); a real navigation throws both away.
    page.execute_script('window.__sameDocument = true')

    find("footer a[href='#{support_path}']", match: :first).click

    # Settle the navigation before touching the DOM. A real page load swaps the
    # document out from under Capybara, and a node looked up mid-swap comes back
    # as `<<ERROR>>` rather than being retried — which is how this example went
    # red on a loaded box while the screenshot showed the support page rendered
    # perfectly (review 1 loop 2, N8). The URL settles first, then the heading.
    expect(page).to have_current_path(support_path)
    expect(page).to have_css('h1', text: 'Contact support', wait: 10)

    # The proof is unchanged: the mark lived on the previous document's window,
    # so only a real navigation can have thrown it away.
    expect(page.evaluate_script('window.__sameDocument')).to be_nil
    expect(page).to have_css('meta[name="turbo-visit-control"][content="reload"]', visible: :all)
  end

  it 'opens and closes the phone menu from the keyboard' do
    page.driver.resize(390, 844)
    visit '/'

    # The bundle is deferred: wait until the element has upgraded before pressing keys.
    expect(page).to have_css('marketing-menu[data-ready]')
    toggle = find('button[aria-controls="marketing-nav"]')
    expect(toggle['aria-expanded']).to eq('false')
    expect(page).to have_css('#marketing-nav', visible: :hidden)

    # Real key presses through the browser's keyboard (Node#send_keys fires
    # synthetic events, which a button does not turn into a click).
    page.execute_script('document.querySelector(\'button[aria-controls="marketing-nav"]\').focus()')
    keyboard.type(:enter)

    expect(toggle['aria-expanded']).to eq('true')
    within('#marketing-nav') do
      expect(page).to have_link('Pricing', visible: :visible)
      expect(page).to have_link('Trust', visible: :visible)
      expect(page).to have_link('Sign In', visible: :visible)
    end
    expect(no_horizontal_overflow?).to be(true)
    page.driver.browser.screenshot(path: screenshot_dir.join('menu-390.png').to_s)

    keyboard.type(:escape)

    expect(toggle['aria-expanded']).to eq('false')
    expect(page).to have_css('#marketing-nav', visible: :hidden)
  end

  it 'lays the desktop nav out inline with no toggle' do
    page.driver.resize(1440, 900)
    visit '/'

    expect(page).to have_css('button[aria-controls="marketing-nav"]', visible: :hidden)
    within('nav[aria-label="Main"]') { expect(page).to have_link('Pricing', visible: :visible) }
  end

  # Capybara.disable_animation injects `animation-duration: 0s !important` into
  # every page the test server serves, so the computed-duration check below
  # passes with or without our rule and cannot fail on its own. The proof is
  # the compiled stylesheet: a `prefers-reduced-motion: reduce` block whose
  # animation-duration is at most 0.01ms.
  it 'stills the hero animation under prefers-reduced-motion and ships the rule in the stylesheet' do
    page.driver.browser.page.command('Emulation.setEmulatedMedia',
                                     features: [{ name: 'prefers-reduced-motion', value: 'reduce' }])
    visit '/'

    duration = page.evaluate_script("getComputedStyle(document.querySelector('.mk-hero-sign')).animationDuration")
    seconds = duration.end_with?('ms') ? duration.to_f / 1000 : duration.to_f
    expect(seconds).to be <= 0.01
    # And the resting picture IS the finished one: nothing to animate towards
    # means the signature is drawn and the seal is showing from the first paint.
    expect(hero_settled?).to be(true)

    reduced_motion_rules = page.evaluate_script(<<~JS)
      Array.from(document.styleSheets).flatMap((sheet) => {
        try {
          return Array.from(sheet.cssRules)
            .filter((rule) => rule.media && rule.media.mediaText.includes('prefers-reduced-motion: reduce'))
            .map((rule) => rule.cssText)
        } catch (e) { return [] }
      })
    JS
    expect(reduced_motion_rules).not_to be_empty
    durations = reduced_motion_rules.join.scan(/animation-duration:\s*([\d.]+)(ms|s)/)
    expect(durations).not_to be_empty
    durations.each do |value, unit|
      expect(unit == 'ms' ? value.to_f / 1000 : value.to_f).to be <= 0.00001
    end
    expect(page).to have_no_css('.mk-reveal')
  ensure
    page.driver.browser.page.command('Emulation.setEmulatedMedia', features: [])
  end
end
