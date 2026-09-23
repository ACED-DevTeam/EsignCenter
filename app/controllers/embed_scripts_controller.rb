# frozen_string_literal: true

class EmbedScriptsController < ActionController::Metal
  BUILDER_SCRIPT = <<~JAVASCRIPT
    (() => {
      const EVENT_SOURCE = 'esigncenter-builder';

      class EsigncenterBuilder extends HTMLElement {
        connectedCallback() {
          const src = this.dataset.src || this.getAttribute('src');

          this.dispatchEvent(new CustomEvent('init'));

          if (!src) {
            this.innerHTML = '<div style="font-family: Arial, sans-serif; padding: 16px;">Missing EsignCenter builder source.</div>';
            return;
          }

          const iframe = document.createElement('iframe');

          iframe.src = this.buildSrc(src);
          iframe.title = this.dataset.title || 'EsignCenter template builder';
          iframe.style.border = '0';
          iframe.style.display = 'block';
          iframe.style.width = '100%';
          iframe.style.minHeight = this.dataset.height || '1000px';
          iframe.style.height = this.dataset.height || '1000px';
          iframe.referrerPolicy = 'strict-origin-when-cross-origin';
          iframe.allow = 'clipboard-write';

          iframe.addEventListener('load', () => {
            this.dispatchEvent(new CustomEvent('iframe-load', { detail: { src: iframe.src } }));
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
            locale: this.dataset.locale
          };

          Object.entries(params).forEach(([key, value]) => {
            if (value !== undefined && value !== null && value !== '') {
              url.searchParams.set(key, value);
            }
          });

          return url.toString();
        }
      }

      if (!window.customElements.get('esigncenter-builder')) {
        window.customElements.define('esigncenter-builder', EsigncenterBuilder);
      }
    })();
  JAVASCRIPT

  FORM_SCRIPT = <<~JAVASCRIPT
    (() => {
      const EVENT_SOURCE = 'esigncenter-form';

      class EsigncenterForm extends HTMLElement {
        connectedCallback() {
          const src = this.dataset.src || this.getAttribute('src');

          this.dispatchEvent(new CustomEvent('init'));

          if (!src) {
            this.innerHTML = '<div style="font-family: Arial, sans-serif; padding: 16px;">Missing EsignCenter form source.</div>';
            return;
          }

          const iframe = document.createElement('iframe');

          iframe.src = this.buildSrc(src);
          iframe.title = this.dataset.title || 'EsignCenter signing form';
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
            embed: '1',
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

    if (!window.customElements.get('esigncenter-form')) {
        window.customElements.define('esigncenter-form', EsigncenterForm);
    }
    })();
  JAVASCRIPT

  def show
    headers['Content-Type'] = 'application/javascript'

    script = if params[:filename].in?(%w[form form.js])
               FORM_SCRIPT
             elsif params[:filename].in?(%w[builder builder.js])
               BUILDER_SCRIPT
             end

    if script
      self.response_body = script
      self.status = 200
    else
      self.response_body = ''
      self.status = 404
    end
  end
end
