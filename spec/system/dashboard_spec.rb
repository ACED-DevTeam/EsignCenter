# frozen_string_literal: true

RSpec.describe 'Dashboard Page' do
  let!(:account) { create(:account) }
  let!(:user) { create(:user, account:) }

  before do
    sign_in(user)
  end

  context 'when are no templates' do
    it 'shows empty state' do
      visit root_path

      expect(page).to have_link('Create', href: new_template_path)
    end
  end

  context 'when there are templates' do
    let!(:authors) { create_list(:user, 5, account:) }
    let!(:templates) { authors.map { |author| create(:template, account:, author:) } }
    let!(:other_template) { create(:template, account: create(:user).account) }

    before do
      visit root_path
    end

    it 'shows the list of templates' do
      templates.each do |template|
        expect(page).to have_content(template.name)
        expect(page).to have_content(template.author.full_name)
      end

      expect(page).to have_content('Templates')
      expect(page).to have_no_content(other_template.name)
      expect(page).to have_link('Create', href: new_template_path)
    end

    it 'initializes the template creation process' do
      click_link 'Create'

      within('#modal') do
        fill_in 'template[name]', with: 'New Template'

        expect do
          click_button 'Create'
        end.to change(Template, :count).by(1)

        expect(page).to have_current_path(edit_template_path(Template.last), ignore_query: true)
      end
    end

    it 'searches be submitter email' do
      submission = create(:submission, :with_submitters, template: templates[0])
      submitter = submission.submitters.first

      SearchEntries.reindex_all

      visit root_path(q: submitter.email)

      expect(page).to have_content('Templates not Found')
      expect(page).to have_content('Submissions')
      expect(page).to have_content(submitter.name)
    end
  end

  # Reviewer Q (finding Q2). Taking the upload form away from a read-only
  # dashboard left the cards themselves registered as drop targets, so a real
  # drop threw "Cannot set properties of undefined (setting 'action')" and
  # left the card greyed out under a spinner that never stopped. This is the
  # browser proof: a genuine drop event carrying a genuine File, dispatched at
  # the card, in Chromium.
  context 'when the reader may not create templates' do
    let!(:template) { create(:template, account:, author: user) }

    before do
      user.update!(read_only_at: Time.current)

      visit root_path
    end

    def drop_a_file_on_the_template_card
      page.execute_script(<<~JS)
        window.dashboardDropErrors = []
        window.addEventListener('error', (event) => window.dashboardDropErrors.push(event.message))

        const card = document.querySelector('a[href="/templates/#{template.id}"]')
        const transfer = new DataTransfer()

        transfer.items.add(new File(['a document'], 'dropped.pdf', { type: 'application/pdf' }))

        card.dispatchEvent(new DragEvent('drop', { dataTransfer: transfer, bubbles: true, cancelable: true }))
      JS
    end

    it 'ignores a file dropped on a template card: no spinner, no exception, no upload' do
      expect(page).to have_content(template.name)
      expect(page).to have_no_css('#dashboard_dropzone_input', visible: :all)

      expect { drop_a_file_on_the_template_card }.not_to change(Template, :count)

      expect(page).to have_no_css('.animate-spin')
      expect(page).to have_no_css('.opacity-50')
      expect(page.evaluate_script('window.dashboardDropErrors')).to eq([])
      expect(page).to have_content(template.name)
    end
  end
end
