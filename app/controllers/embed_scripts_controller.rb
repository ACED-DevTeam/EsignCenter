# frozen_string_literal: true

class EmbedScriptsController < ActionController::Metal
  BUILDER_PLACEHOLDER_SCRIPT = <<~JAVASCRIPT.freeze
    const DummyBuilder = class extends HTMLElement {
      connectedCallback() {
        this.innerHTML = `
          <div style="text-align: center; padding: 20px; font-family: Arial, sans-serif;">
            <h2>Upgrade to Pro</h2>
            <p>Unlock embedded components by upgrading to Pro</p>
            <div style="margin-top: 40px;">
              <a href="#{Docuseal::CONSOLE_URL}/on_premises" target="_blank" style="padding: 15px 25px; background-color: #222; color: white; text-decoration: none; border-radius: 5px; font-size: 16px; cursor: pointer;">
                Learn More
              </a>
            </div>
          </div>
        `;
      }
    };

    if (!window.customElements.get('docuseal-builder')) {
      window.customElements.define('docuseal-builder', DummyBuilder);
    }
  JAVASCRIPT

  FORM_SCRIPT = <<~JAVASCRIPT
    (() => {
      const EVENT_SOURCE = 'docuseal-form';

      class DocusealForm extends HTMLElement {
        connectedCallback() {
          const src = this.dataset.src || this.getAttribute('src');

          this.dispatchEvent(new CustomEvent('init'));

          if (!src) {
            this.innerHTML = '<div style="font-family: Arial, sans-serif; padding: 16px;">Missing DocuSeal form source.</div>';
            return;
          }

          const iframe = document.createElement('iframe');

          iframe.src = this.buildSrc(src);
          iframe.title = this.dataset.title || 'DocuSeal signing form';
          iframe.style.border = '0';
          iframe.style.display = 'block';
          iframe.style.width = '100%';
          iframe.style.minHeight = this.dataset.height || '1000px';
          iframe.style.height = this.dataset.height || '1000px';
          iframe.referrerPolicy = 'strict-origin-when-cross-origin';
          iframe.allow = 'clipboard-write';

          iframe.addEventListener('load', () => {
            this.dispatchEvent(new CustomEvent('load', { detail: { src: iframe.src } }));
          });

          this.innerHTML = '';
          this.appendChild(iframe);
          this.iframe = iframe;

          this.messageHandler = (event) => {
            let iframeOrigin;

            try {
              iframeOrigin = new URL(iframe.src, window.location.href).origin;
            } catch (_error) {
              return;
            }

            if (event.origin !== iframeOrigin) return;
            if (!event.data || event.data.source !== EVENT_SOURCE || !event.data.event) return;

            this.dispatchEvent(new CustomEvent(event.data.event, { detail: event.data.detail || {} }));
          };

          window.addEventListener('message', this.messageHandler);
        }

        disconnectedCallback() {
          if (this.messageHandler) {
            window.removeEventListener('message', this.messageHandler);
          }

          this.iframe?.remove();
        }

        buildSrc(src) {
          const url = new URL(src, window.location.href);
          const params = {
            email: this.dataset.email,
            name: this.dataset.name,
            role: this.dataset.role,
            token: this.dataset.token,
            preview: this.dataset.preview,
            expand: this.dataset.expand,
            minimize: this.dataset.minimize,
            completed_redirect_url: this.dataset.completedRedirectUrl
          };

          Object.entries(params).forEach(([key, value]) => {
            if (value !== undefined && value !== null && value !== '') {
              url.searchParams.set(key, value);
            }
          });

          return url.toString();
        }
      }

    if (!window.customElements.get('docuseal-form')) {
        window.customElements.define('docuseal-form', DocusealForm);
    }
    })();
  JAVASCRIPT

  def show
    headers['Content-Type'] = 'application/javascript'

    self.response_body = if params[:filename].in?(%w[form form.js])
                           FORM_SCRIPT
                         else
                           BUILDER_PLACEHOLDER_SCRIPT
                         end

    self.status = 200
  end
end
