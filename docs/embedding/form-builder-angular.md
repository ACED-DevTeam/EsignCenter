# Angular Form Builder

### Example Code

```angular
import { Component, CUSTOM_ELEMENTS_SCHEMA, OnInit } from '@angular/core';
import { NgIf } from '@angular/common';
import { HttpClient } from '@angular/common/http';

@Component({
  selector: 'app-root',
  standalone: true,
  imports: [NgIf],
  schemas: [CUSTOM_ELEMENTS_SCHEMA],
  template: `
    <div class="app">
      <ng-container *ngIf="builderSrc">
        <esigncenter-builder
          [attr.data-src]="builderSrc"
          (save)="onSave($event)">
        </esigncenter-builder>
      </ng-container>
    </div>
  `
})
export class AppComponent implements OnInit {
  builderSrc: string = ''

  constructor(private http: HttpClient) {}

  ngOnInit() {
    const script = document.createElement('script');
    script.src = 'https://your-instance.example.com/js/builder.js';
    script.async = true;
    document.head.appendChild(script);

    this.http.post('/api/esigncenter/builder_session', {}).subscribe((data: any) => {
      this.builderSrc = data.builder_src;
    });
  }

  onSave(event: Event) {
    console.log('Template saved', (event as CustomEvent).detail.template);
  }
}

```

```javascript
// Your backend endpoint (e.g. POST /api/esigncenter/builder_session) creates a
// short-lived builder session. Keep the EsignCenter API key on the backend.
const response = await fetch('https://your-instance.example.com/api/template_builder_sessions', {
  method: 'POST',
  headers: {
    'X-Auth-Token': '{{api_key}}',
    'Content-Type': 'application/json'
  },
  body: JSON.stringify({
    name: 'Integration W-9 Test Form',
    external_id: 'TestForm123',
    embed_origin: 'https://your-app.example.com',
    documents: [
      {
        name: 'fw9.pdf',
        file: 'BASE64_ENCODED_PDF'
      }
    ]
  })
});

const { builder_src } = await response.json();

```

`<esigncenter-builder>` is a web component served by your EsignCenter instance at `/js/builder.js`, not an Angular component — add `CUSTOM_ELEMENTS_SCHEMA` to the component (or module) `schemas` and bind the `builder_src` returned by `POST /api/template_builder_sessions` with `[attr.data-src]`.

### Attributes

```json
{
  "token": {
    "type": "string",
    "doc_type": "object",
    "description": "JSON Web Token (JWT HS256) with a payload signed using the API key. <br><b>Ensure that the JWT token is generated on the backend to prevent unauthorized access to your documents</b>.",
    "required": true,
    "properties": {
      "user_email": {
        "type": "string",
        "required": true,
        "description": "Email of the owner of the API signing key - admin user email."
      },
      "integration_email": {
        "type": "string",
        "required": false,
        "description": "Email of the user to create a template for.",
        "example": "signer@example.com"
      },
      "template_id": {
        "type": "number",
        "required": false,
        "description": "ID of the template to open in the form builder. Optional when `document_urls` are specified."
      },
      "external_id": {
        "type": "string",
        "description": "Your application-specific unique string key to identify this template within your app.",
        "required": false
      },
      "folder_name": {
        "type": "string",
        "description": "The folder name in which the template should be created.",
        "required": false
      },
      "document_urls": {
        "type": "array",
        "required": false,
        "description": "An Array of URLs with PDF files to open in the form builder. Optional when `template_id` is specified.",
        "example": "['https://www.irs.gov/pub/irs-pdf/fw9.pdf']"
      },
      "name": {
        "type": "string",
        "required": false,
        "description": "New template name when creating a template with document_urls specified.",
        "example": "Integration W-9 Test Form"
      },
      "extract_fields": {
        "type": "boolean",
        "required": false,
        "description": "Pass `false` to disable automatic PDF form fields extraction. PDF fields are automatically added by default."
      }
    }
  },
  "host": {
    "type": "string",
    "required": false,
    "description": "EsignCenter host domain name, e.g. your-instance.example.com.",
    "example": "yourdomain.com"
  },
  "customButton": {
    "type": "object",
    "required": false,
    "description": "Custom button will be displayed on the top right corner of the form builder.",
    "properties": {
      "title": {
        "type": "string",
        "required": true,
        "description": "Custom button title."
      },
      "url": {
        "type": "string",
        "required": true,
        "description": "Custom button URL. Only absolute URLs are supported."
      }
    }
  },
  "roles": {
    "type": "array",
    "required": false,
    "description": "Submitter role names to be used by default in the form."
  },
  "fieldTypes": {
    "type": "array",
    "required": false,
    "description": "Field type names to be used in the form builder. All field types are used by default.",
    "enum": [
      "heading",
      "text",
      "signature",
      "initials",
      "date",
      "datenow",
      "number",
      "image",
      "checkbox",
      "multiple",
      "file",
      "radio",
      "select",
      "cells",
      "stamp",
      "payment",
      "phone",
      "verification",
      "strikethrough"
    ]
  },
  "drawFieldType": {
    "type": "string",
    "required": false,
    "default": "text",
    "description": "Field type to be used by default with the field drawing tool.",
    "example": "signature"
  },
  "fields": {
    "type": "array",
    "required": false,
    "description": "An array of default custom field properties with `name` to be added to the document.",
    "items": {
      "type": "object",
      "properties": {
        "name": {
          "type": "string",
          "required": true,
          "description": "Field name."
        },
        "type": {
          "type": "string",
          "required": false,
          "description": "Field type.",
          "enum": [
            "heading",
            "text",
            "signature",
            "initials",
            "date",
            "number",
            "image",
            "checkbox",
            "multiple",
            "file",
            "radio",
            "select",
            "cells",
            "stamp",
            "payment",
            "phone",
            "verification",
            "strikethrough"
          ]
        },
        "role": {
          "type": "string",
          "required": false,
          "description": "Submitter role name for the field."
        },
        "default_value": {
          "type": "string",
          "required": false,
          "description": "Default value of the field."
        },
        "title": {
          "type": "string",
          "required": false,
          "description": "Field title displayed to the user instead of the name, shown on the signing form. Supports Markdown."
        },
        "description": {
          "type": "string",
          "required": false,
          "description": "Field description displayed on the signing form. Supports Markdown."
        },
        "width": {
          "type": "number",
          "required": false,
          "description": "Field width in pixels."
        },
        "height": {
          "type": "number",
          "required": false,
          "description": "Field height in pixels."
        },
        "format": {
          "type": "string",
          "required": false,
          "description": "Field format. Depends on the field type."
        },
        "options": {
          "type": "array",
          "required": false,
          "description": "Field options. Required for the select field type."
        },
        "validation": {
          "type": "object",
          "required": false,
          "description": "Field validation rules.",
          "properties": {
            "pattern": {
              "type": "string",
              "required": false,
              "description": "Field pattern.",
              "example": "^[0-9]{5}$"
            },
            "message": {
              "type": "string",
              "required": false,
              "description": "Validation error message."
            }
          }
        }
      }
    }
  },
  "submitters": {
    "type": "array",
    "required": false,
    "description": "An array of default submitters with `role` name to be added to the document.",
    "items": {
      "type": "object",
      "properties": {
        "email": {
          "type": "string",
          "required": false,
          "description": "Submitter email."
        },
        "role": {
          "type": "string",
          "required": true,
          "description": "Submitter role name."
        },
        "name": {
          "type": "string",
          "required": false,
          "description": "Submitter name."
        },
        "phone": {
          "type": "string",
          "required": false,
          "description": "Submitter phone number, formatted according to the E.164 standard."
        }
      }
    }
  },
  "requiredFields": {
    "type": "array",
    "required": false,
    "description": "An array of default required custom field properties with `name` that should be added to the document.",
    "items": {
      "type": "object",
      "properties": {
        "name": {
          "type": "string",
          "required": true,
          "description": "Field name."
        },
        "type": {
          "type": "string",
          "required": false,
          "description": "Field type.",
          "enum": [
            "heading",
            "text",
            "signature",
            "initials",
            "date",
            "number",
            "image",
            "checkbox",
            "multiple",
            "file",
            "radio",
            "select",
            "cells",
            "stamp",
            "payment",
            "phone",
            "verification",
            "strikethrough"
          ]
        },
        "role": {
          "type": "string",
          "required": false,
          "description": "Submitter role name for the field."
        },
        "default_value": {
          "type": "string",
          "required": false,
          "description": "Default value of the field."
        },
        "title": {
          "type": "string",
          "required": false,
          "description": "Field title displayed to the user instead of the name, shown on the signing form. Supports Markdown."
        },
        "description": {
          "type": "string",
          "required": false,
          "description": "Field description displayed on the signing form. Supports Markdown."
        },
        "width": {
          "type": "number",
          "required": false,
          "description": "Field width in pixels."
        },
        "height": {
          "type": "number",
          "required": false,
          "description": "Field height in pixels."
        },
        "format": {
          "type": "string",
          "required": false,
          "description": "Field format. Depends on the field type."
        },
        "options": {
          "type": "array",
          "required": false,
          "description": "Field options. Required for the select field type."
        },
        "validation": {
          "type": "object",
          "required": false,
          "description": "Field validation rules.",
          "properties": {
            "pattern": {
              "type": "string",
              "required": false,
              "description": "Field pattern.",
              "example": "^[0-9]{5}$"
            },
            "message": {
              "type": "string",
              "required": false,
              "description": "Validation error message."
            }
          }
        }
      }
    }
  },
  "emailMessage": {
    "type": "object",
    "required": false,
    "description": "Email subject and body for the signature request.",
    "properties": {
      "subject": {
        "type": "string",
        "required": true,
        "description": "Email subject for the signature request."
      },
      "body": {
        "type": "string",
        "required": true,
        "description": "Email body for the signature request."
      }
    }
  },
  "withTitle": {
    "type": "boolean",
    "required": false,
    "default": true,
    "description": "Set `false` to remove document title from the builder."
  },
  "withSendButton": {
    "type": "boolean",
    "required": false,
    "default": true,
    "description": "Show the \"Send\" button."
  },
  "withUploadButton": {
    "type": "boolean",
    "required": false,
    "default": true,
    "description": "Show the \"Upload\" button."
  },
  "withAddPageButton": {
    "type": "boolean",
    "required": false,
    "default": false,
    "description": "Show the \"Add Blank Page\" button."
  },
  "withSignYourselfButton": {
    "type": "boolean",
    "required": false,
    "default": true,
    "description": "Show the \"Sign Yourself\" button."
  },
  "withDocumentsList": {
    "type": "boolean",
    "required": false,
    "default": true,
    "description": "Set `false` to now show the documents list on the left. Documents list is displayed by default."
  },
  "withFieldsList": {
    "type": "boolean",
    "required": false,
    "default": true,
    "description": "Set `false` to now show the fields list on the right. Fields list is displayed by default."
  },
  "withFieldsDetection": {
    "type": "boolean",
    "required": false,
    "default": false,
    "description": "Display a button to automatically detect and add fields to the document with AI."
  },
  "withFieldPlaceholder": {
    "type": "boolean",
    "required": false,
    "default": false,
    "description": "Set `true` to display field name placeholders instead of the field type icons."
  },
  "withSignatureId": {
    "type": "boolean",
    "required": false,
    "description": "Set to `true` to enable Signature ID by default for newly added fields. If set to `false`, the Signature ID toggle will be displayed under field settings, with the Signature ID turned off by default."
  },
  "onlyDefinedFields": {
    "type": "boolean",
    "required": false,
    "default": false,
    "description": "Allow to add fields only defined in the `fields` prop."
  },
  "preview": {
    "type": "boolean",
    "required": false,
    "default": false,
    "description": "Show template in preview mode without ability to edit it."
  },
  "inputMode": {
    "type": "boolean",
    "required": false,
    "default": false,
    "description": "Open template in data input mode to prefill fields with default values."
  },
  "autosave": {
    "type": "boolean",
    "required": false,
    "default": true,
    "description": "Set `false` to disable form changes autosaving."
  },
  "language": {
    "type": "string",
    "required": false,
    "default": "en",
    "description": "UI language, 'en', 'es', 'de', 'fr', 'pt', 'nl', 'he', 'ar' languages are available."
  },
  "i18n": {
    "type": "object",
    "required": false,
    "default": "{}",
    "description": "Object that contains i18n keys to replace the default UI text with custom values. See <a href=\"https://github.com/AmishHillBilly/EsignCenter/blob/master/app/javascript/template_builder/i18n.js\" class=\"link\" target=\"_blank\" rel=\"nofollow\">template_builder/i18n.js</a> for available i18n keys."
  },
  "backgroundColor": {
    "type": "string",
    "required": false,
    "description": "The form builder background color. Only HEX color codes are supported.",
    "example": "#ffffff"
  },
  "customCss": {
    "type": "string",
    "required": false,
    "description": "Custom CSS styles to be applied to the form builder.",
    "example": "#sign_yourself_button { background-color: #FFA500; }"
  }
}
```

### Callback

```json
{
  "onLoad": {
    "type": "event emitter",
    "required": false,
    "description": "Event emitted on loading the form builder template data.",
    "example": "handleLoad($event)"
  },
  "onUpload": {
    "type": "event emitter",
    "required": false,
    "description": "Event emitted on uploading a document to the template.",
    "example": "handleUpload($event)"
  },
  "onSend": {
    "type": "event emitter",
    "required": false,
    "description": "Event emitted on sending documents for signature to recipients.",
    "example": "handleSend($event)"
  },
  "onChange": {
    "type": "function",
    "required": false,
    "description": "Function to be called when changes are made to the template form.",
    "example": "handleChange($event)"
  },
  "onSave": {
    "type": "event emitter",
    "required": false,
    "description": "Event emitted on saving changes of the template form.",
    "example": "handleSave($event)"
  }
}
```
