# frozen_string_literal: true

# The furniture every page carries, in a real browser (Session 9 Phase D).
#
# The flash is one shared partial used under two layouts. It positions itself
# `absolute top-0` with no positioned ancestor, which lands it at the top of
# the viewport — fine in the app layout, and straight underneath the marketing
# layout's sticky z-30 header, where "Signed out successfully." was drawn
# behind the wordmark and nobody ever saw it.
RSpec.describe 'The app chrome' do
  let!(:user) { create(:user) }

  it 'draws a flash above the sticky header on a marketing page' do
    sign_in(user)
    visit '/settings/profile'

    # Sign out lives in the navbar's account menu, which opens on focus.
    find('.dropdown > label[tabindex]').click
    click_button I18n.t('sign_out')

    # Sign-out lands on the public landing page, which uses the marketing
    # layout — the flash's hard case.
    expect(page).to have_css('header.sticky')
    expect(page).to have_css('#flash')
    expect(page).to have_content('Signed out successfully.')

    # Not merely present: on top of the header and inside the window, which is
    # what a substring check in the body would never have caught.
    placement = page.evaluate_script(<<~JS)
      (function () {
        // #flash is a zero-height positioning shell; the card inside it is the
        // thing a reader sees, so that is what gets measured and hit-tested.
        var flash = document.querySelector('#flash');
        var card = flash.querySelector('.rounded-2xl');
        var head = document.querySelector('header.sticky').getBoundingClientRect();
        var box = card.getBoundingClientRect();
        var hit = document.elementFromPoint(box.left + box.width / 2, box.top + box.height / 2);
        return {
          covered: !!(hit && flash.contains(hit)),
          below_header: box.top >= head.bottom - 1,
          on_screen: box.top >= 0 && box.bottom <= window.innerHeight,
          width: Math.round(box.width),
          height: Math.round(box.height)
        };
      })()
    JS

    expect(placement['width']).to be > 0
    expect(placement['height']).to be > 0
    expect(placement['below_header']).to be(true), 'the flash was drawn under the sticky header'
    expect(placement['on_screen']).to be(true)
    expect(placement['covered']).to be(true), 'something else is painted on top of the flash'
  end

  it 'draws the same flash on a phone without pushing the page sideways' do
    page.driver.resize(390, 844)
    sign_in(user)
    visit '/settings/profile'

    find('.dropdown > label[tabindex]').click
    click_button I18n.t('sign_out')

    expect(page).to have_content('Signed out successfully.')
    expect(page.evaluate_script('document.documentElement.scrollWidth <= document.documentElement.clientWidth'))
      .to be(true)
  end
end
