# frozen_string_literal: true

module SigningFormHelper
  module_function

  def draw_canvas
    page.execute_script <<~JS
      const canvas = document.getElementsByTagName('canvas')[0];
      const rect = canvas.getBoundingClientRect();

      const startX = rect.left + 50;
      const startY = rect.top + 100;

      const amplitude = 20;
      const wavelength = 30;
      const length = 300;

      function dispatchPointerEvent(type, x, y) {
        const event = new PointerEvent(type, {
          pointerId: 1,
          pointerType: 'pen',
          isPrimary: true,
          clientX: x,
          clientY: y,
          bubbles: true,
          pressure: 0.5
        });

        canvas.dispatchEvent(event);
      }

      dispatchPointerEvent('pointerdown', startX, startY);

      let x = 0;
      function drawStep() {
        if (x > length) {
          dispatchPointerEvent('pointerup', startX + x, startY);
          return;
        }

        const y = startY + amplitude * Math.sin((x / wavelength) * 2 * Math.PI);
        dispatchPointerEvent('pointermove', startX + x, y);
        x += 5;
        requestAnimationFrame(drawStep);
      }

      drawStep();
    JS

    sleep 0.1
  end

  # Ticks the ESIGN consent box when the form shows one (a signer who has not
  # consented yet). Completion buttons stay disabled until it is ticked. Call it
  # with the form expanded (after "Sign now" / "Start now" on collapsed steps).
  #
  # The box itself is disabled until the signer has opened the document as a
  # PDF (§7001(c): confirm your device can display the record), so the link
  # goes first.
  #
  # The link opens the PDF in a new tab, which leaves the signing page in the
  # background — and a background tab gets no requestAnimationFrame, which is
  # what draw_canvas rides on, so a signature drawn afterwards would come out
  # as a single dot ("too small or simple"). Real signers come back to the
  # signing tab; the test says so explicitly.
  def agree_to_esign_consent
    return unless page.has_css?('#esign_consent', wait: 5)

    if page.has_css?('#esign_consent_view_pdf', wait: 1)
      find_by_id('esign_consent_view_pdf').click

      return_to_signing_tab
    end

    check 'esign_consent'
  end

  def return_to_signing_tab
    page.driver.browser.page.command('Page.bringToFront')
  rescue StandardError
    nil
  end

  def field_value(submitter, field_name)
    field = template_field(submitter.template, field_name)

    submitter.values[field['uuid']]
  end

  def template_field(template, field_name)
    template.fields.find { |f| f['name'] == field_name || f['title'] == field_name } || {}
  end
end
