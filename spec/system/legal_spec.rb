# frozen_string_literal: true

# The legal pages in a real browser, on a phone.
#
# Both documents carry tables — the free plan's limits, the fair-use numbers,
# the sub-processor list — and a table is the one thing in a prose page that
# can push the whole layout sideways. Each is wrapped in a bare <div> that
# scrolls on its own (the `.legal-document div` rule in application.scss), and
# this is the proof: at 390 x 844, the smallest phone the product supports,
# the document itself never scrolls horizontally.
RSpec.describe 'Legal pages on a phone' do
  before do
    # The instance is set up, so a public page is never the setup redirect.
    create(:user)

    page.driver.resize(390, 844)
  end

  %w[/terms /privacy].each do |path|
    it "renders #{path} without pushing the page sideways" do
      visit path

      expect(page).to have_css('article.legal-document')

      overflow = page.evaluate_script(<<~JS)
        (function () {
          var el = document.scrollingElement || document.documentElement;
          return el.scrollWidth - el.clientWidth;
        })()
      JS

      expect(overflow).to be <= 0
    end
  end
end
