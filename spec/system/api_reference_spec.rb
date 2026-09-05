# frozen_string_literal: true

# The API reference in a real browser (Session 10 Phase B).
#
# The point of this file is the CSP. The whole application runs under
# `script_src 'self'` with no CDN (ApplicationController#set_csp), and the
# reference is a large third-party bundle: the only honest proof that it works
# under that policy is to load it in Chrome and watch for a blocked resource.
#
# Both watchers are installed BEFORE the page is visited — the console and the
# browser's own log through CDP, and a `securitypolicyviolation` listener
# injected into every new document — because a violation during the first
# paint is exactly the one a listener added afterwards would miss.
RSpec.describe 'API reference in the browser' do
  before do
    create(:user, account: create(:account, :operator))
    FileUtils.mkdir_p(screenshot_dir)
    # The reference pack is the largest asset in the application by an order of
    # magnitude, and a cold server serving it for the first time takes longer
    # than the driver's default page-load timeout. The wait is about how slow
    # the first byte is, not about how long anything is allowed to be broken
    # for: every assertion below still has its own.
    page.driver.browser.timeout = 60
    # Attached to the browser target before anything is visited, so a violation
    # during the very first paint is caught. They survive navigation.
    watch_for_trouble!
  end

  def screenshot_dir
    Rails.root.join('tmp/screenshots')
  end

  def cdp
    page.driver.browser.page
  end

  # Collected by the CDP listeners below, which run on Ferrum's own thread: the
  # arrays are taken once here so the blocks close over them rather than
  # reaching back into RSpec from another thread.
  let(:console_errors) { [] }
  let(:browser_log) { [] }

  def watch_for_trouble!
    errors = console_errors
    log = browser_log

    cdp.on('Runtime.consoleAPICalled') do |params, _index|
      next unless params['type'] == 'error'

      errors << Array(params['args']).map { |arg| arg['description'] || arg['value'] }.join(' ')
    end

    cdp.command('Log.enable')
    cdp.on('Log.entryAdded') do |params, _index|
      entry = params['entry'] || {}

      log << "#{entry['source']}: #{entry['text']}" if entry['level'].in?(%w[error warning])
    end

    # Runs before any script of the document it lands in, on every navigation.
    cdp.command('Page.addScriptToEvaluateOnNewDocument', source: <<~JS)
      window.__cspViolations = []
      document.addEventListener('securitypolicyviolation', (event) => {
        window.__cspViolations.push(event.effectiveDirective + ' blocked ' + event.blockedURI)
      })
    JS
  end

  def next_frame
    page.evaluate_async_script(<<~JS)
      const done = arguments[0]
      requestAnimationFrame(() => requestAnimationFrame(() => done(null)))
    JS
  end

  def csp_violations
    page.evaluate_script('window.__cspViolations || []') +
      browser_log.select { |entry| entry.start_with?('security:') }
  end

  def no_horizontal_overflow?
    page.evaluate_script('document.documentElement.scrollWidth <= document.documentElement.clientWidth')
  end

  # Back to the top first: opening a sidebar group scrolls the reference to the
  # operation it names, and the CTO's visual pass wants the page as a reader
  # first meets it, not whatever section happened to be in view.
  def screenshot(name)
    page.execute_script(<<~JS)
      window.scrollTo(0, 0)
      document.querySelectorAll('*').forEach((element) => { if (element.scrollTop) element.scrollTop = 0 })
    JS
    next_frame
    page.driver.browser.screenshot(path: screenshot_dir.join(name).to_s)
  end

  # Scalar mounts asynchronously: it fetches /docs/openapi.json, parses half a
  # megabyte of JSON and renders. An operation name in the sidebar is what
  # "it worked" looks like from outside.
  def wait_for_the_reference
    expect(page).to have_css('#api-reference[data-mounted="true"]', wait: 10)
    # The first tag group is open, so its operations are the proof the document
    # was fetched, parsed and rendered.
    expect(page).to have_content('List all submissions', wait: 60)
  end

  # And the sidebar works: opening a collapsed group reveals its operations.
  def open_the_templates_group
    find('button', text: 'Open Group - Templates', match: :first).click

    expect(page).to have_content('List all templates', wait: 10)
  end

  it 'renders the operation list under the application policy, with no console error and no CSP violation' do
    page.driver.resize(1440, 900)
    visit '/docs/api'

    expect(page).to have_css('h1', text: 'API reference')
    wait_for_the_reference
    open_the_templates_group

    expect(csp_violations).to eq([])
    expect(console_errors).to eq([])
    screenshot('api-reference-1440.png')
  end

  it 'shows the intro, the base URL and the reference on a phone without scrolling sideways' do
    page.driver.resize(390, 844)
    visit '/docs/api'

    expect(page).to have_content("#{Docuseal::DEFAULT_APP_URL}/api")
    expect(page).to have_content('X-Auth-Token')
    wait_for_the_reference

    expect(no_horizontal_overflow?).to be(true), '/docs/api scrolls sideways at 390px'
    expect(csp_violations).to eq([])
    screenshot('api-reference-390.png')
  end

  it 'serves the description from this origin, so the page needs nothing off it' do
    visit '/docs/openapi.json'

    expect(page).to have_content('"openapi"')
    expect(page).to have_no_content('your-instance.example.com')
  end
end
