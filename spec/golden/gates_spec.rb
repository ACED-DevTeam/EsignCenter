# frozen_string_literal: true

require 'rake'

Rails.application.load_tasks unless Rake::Task.task_defined?('gates:account_kind')

# The account-kind gate (REVIEW 4 / S5 carry-over).
#
# `accounts.account_kind` carries a `customer` default, so an account created
# without naming its kind is silently a metered, billable tenant. That is the
# wrong answer for every internal door we have — provisioning, the operator
# seed, test-mode clones — and it is a mistake nobody sees, because the
# account looks perfectly normal until somebody is billed for it or a quota
# refuses a platform job. The gate makes the omission impossible to merge.
#
# Written the way spec/gates/*_spec.rb writes the other two: every check is a
# pure function over (content, relative path), so the gate is proven red on a
# fixture string and green on the real tree without touching either.
# rubocop:disable RSpec/DescribeClass
RSpec.describe 'Account-kind gate' do
  describe 'Gates.account_kind_violations' do
    # The title used to say "every creation form", which is a promise no
    # regex can keep: it can only know the spellings somebody has taught it.
    # What this example really pins is the list below — every idiom in it is
    # caught, and a new idiom is a new line here plus a new verb in the gate
    # (review 10, D-F3: a probe file spelling `create_or_find_by`, `insert!`,
    # `insert_all`, `upsert`, `upsert_all` or `create_with(...)
    # .find_or_create_by` walked straight through a green gate).
    it 'catches each creation spelling it knows, with no kind named' do
      [
        'Account.new(name: name)',
        'Account.create(name: name)',
        'Account.create!(name: name)',
        'account.accounts.new(name: name)',
        'account.accounts.create(name: name)',
        'account.accounts.create!(name: name)',
        'Account . create!( name: name )',
        "Account.create!(\n  name: name,\n  timezone: 'UTC'\n)",
        'Account.create!(name: helper(other(1)))',
        # Review 2 (M2/M3): the ordinary Rails idioms the first version of the
        # gate walked straight past. Every one of these mints a `customer`
        # account by default.
        'Account.new',
        'Account.create name: name',
        'Account.build(name: name)',
        'user.accounts.build(name: name)',
        'accounts.create!(name: name)',
        'accounts.build(name: name)',
        'Account.find_or_create_by(name: name)',
        'Account.find_or_create_by!(name: name)',
        'Account.first_or_create(name: name)',
        'user.accounts.first_or_create!(name: name)',
        # Review 2 (N5): the same verbs as they are actually written — behind
        # a scope. `first_or_create` is essentially never spelled without a
        # `where` in front of it, which is where the fix that added the verb
        # left the hole it was closing.
        'Account.where(name: name).first_or_create!(timezone: zone)',
        'Account.where(name: name).first_or_create',
        'user.accounts.where(name: name).create!(timezone: zone)',
        'Account.unscoped.new(name: name)',
        'Account.where(name: name).where.not(archived_at: nil).first_or_create!(timezone: zone)',
        'account.dup',
        'testing_account = account.dup',
        # Review 10 (D-F3). The rest of Rails' creation vocabulary: the
        # find-or-create twin that races safely, the three bulk writers that
        # go straight to SQL — and therefore straight past every model
        # default the console would have applied — and the scope that carries
        # the attributes for a `find_or_create_by` in front of it.
        'Account.create_or_find_by(name: name)',
        'Account.create_or_find_by!(name: name)',
        'user.accounts.create_or_find_by!(name: name)',
        'Account.insert({ name: name })',
        'Account.insert!({ name: name })',
        'Account.insert_all([{ name: name }])',
        'Account.insert_all!([{ name: name }])',
        'Account.upsert({ name: name })',
        'Account.upsert_all([{ name: name }])',
        'Account.create_with(name: name).find_or_create_by(timezone: zone)',
        'Account.create_with(name: name).first_or_create!',
        "Account.upsert_all(\n  [{ name: name }],\n  unique_by: :id\n)",
        # A string that merely spells the argument out is not the argument.
        "Account.new(name: 'account_kind: internal')"
      ].each do |snippet|
        expect(Gates.account_kind_violations("#{snippet}\n", 'lib/probe.rb')).to have_attributes(size: 1), snippet
      end
    end

    # The two `.dup` sites in lib/accounts.rb are the tree's only real
    # non-signup creators, and they pass by being named in the allowlist with
    # the reason (a copy inherits the original's kind) — never by accident.
    it 'passes the reviewed dup sites and nothing else' do
      expect(Gates.account_kind_violations("new_account = account.dup\n", 'lib/accounts.rb')).to be_empty
      expect(Gates.account_kind_violations("new_account = account.dup\n", 'lib/other.rb')).to have_attributes(size: 1)
    end

    # A creation site parked inside a comment creates nothing.
    it 'ignores creations inside comments' do
      expect(Gates.account_kind_violations("# Account.create!(name: name)\n", 'lib/probe.rb')).to be_empty
    end

    # Review 2 (N6). The gate blanks strings and comments before it looks for
    # creations, and an apostrophe in heredoc PROSE — which is most of the
    # prose in this codebase — used to open a string that ran to the next
    # apostrophe anywhere in the file, blanking every line between them. The
    # gate then reported nothing and looked green: failing open, silently.
    it 'does not let an apostrophe in heredoc prose blank the code after it' do
      snippet = <<~RUBY
        BODY = <<~TXT
          the customer's name
        TXT

        def make(name)
          Account.create!(name: name)
        end

        NOTE = <<~TXT
          it's fine
        TXT
      RUBY

      expect(Gates.account_kind_violations(snippet, 'lib/probe.rb')).to have_attributes(size: 1)
    end

    # The same failure without a heredoc: a quoted string is a SINGLE line, so
    # an unbalanced quote can cost at most the line it is on.
    it 'does not let an unbalanced quote blank the lines below it' do
      snippet = "puts 'unterminated\nAccount.create!(name: name)\n"

      expect(Gates.account_kind_violations(snippet, 'lib/probe.rb')).to have_attributes(size: 1)
    end

    # ...and a heredoc body is still prose: a creation spelled out inside one
    # creates nothing.
    it 'ignores a creation inside a heredoc body' do
      snippet = "DOC = <<~TXT\n  Account.create!(name: name)\nTXT\n"

      expect(Gates.account_kind_violations(snippet, 'lib/probe.rb')).to be_empty
    end

    it 'accepts a creation that names the kind anywhere inside the same call' do
      [
        'Account.new(account_kind: Account::CUSTOMER_KIND)',
        'Account.create!(name: name, account_kind: Account::INTERNAL_KIND)',
        "Account.create!(\n  name: name,\n  account_kind: Account::OPERATOR_KIND\n)",
        'user.accounts.create!(name: name, account_kind: kind)',
        'Account.new(params.merge(account_kind: Account::INTERNAL_KIND))',
        'Account.build(name: name, account_kind: kind)',
        'accounts.create!(name: name, account_kind: kind)',
        'Account.find_or_create_by!(name: name, account_kind: kind)',
        'Account.create name: name, account_kind: kind',
        'Account.where(name: name).first_or_create!(account_kind: kind)',
        'user.accounts.where(name: name).create!(account_kind: kind)',
        # Review 10 (D-F3): the new spellings, said properly.
        'Account.create_or_find_by!(name: name, account_kind: kind)',
        'Account.insert!({ name: name, account_kind: kind })',
        'Account.insert_all([{ name: name, account_kind: kind }])',
        'Account.upsert({ name: name, account_kind: kind })',
        'Account.upsert_all([{ name: name, account_kind: kind }])',
        'Account.create_with(account_kind: kind).find_or_create_by(name: name)'
      ].each do |snippet|
        expect(Gates.account_kind_violations("#{snippet}\n", 'lib/probe.rb')).to be_empty, snippet
      end
    end

    # The kind has to be inside THIS call. A neighbouring assignment reads
    # fine to a human and leaves the record unsaved-with-a-default in the
    # window between the two lines — and, more to the point, a gate that
    # accepted it would accept a kind set on some other object entirely.
    it 'does not accept a kind set on the next line instead of in the call' do
      snippet = "account = Account.new(name: name)\naccount.account_kind = Account::INTERNAL_KIND\n"

      expect(Gates.account_kind_violations(snippet, 'lib/probe.rb')).to have_attributes(size: 1)
    end

    # The scope segments are a NAMED list of relation methods for this reason:
    # the receiver may be an association, so "any chained method" would read
    # every `account.<association>.create!` in the tree as an account creation.
    it 'ignores a creation on something else that merely hangs off an account' do
      [
        'account.templates.create!(name: name)',
        'account.users.create!(email: email)',
        'user.accounts.first.templates.create!(name: name)'
      ].each do |snippet|
        expect(Gates.account_kind_violations("#{snippet}\n", 'lib/probe.rb')).to be_empty, snippet
      end
    end

    it 'ignores models whose name merely starts with Account' do
      [
        "AccountConfig.new(account: account, key: 'x')",
        'AccountInvite.create!(account: account, email: email)',
        'AccountCounters.new(account_id: account.id)'
      ].each do |snippet|
        expect(Gates.account_kind_violations("#{snippet}\n", 'lib/probe.rb')).to be_empty, snippet
      end
    end

    # Specs and factories build accounts by the hundred and a factory default
    # is a decision somebody made on purpose, so only shipping code is scanned.
    it 'scans app/ and lib/ only' do
      snippet = "Account.create!(name: name)\n"

      expect(Gates.account_kind_violations(snippet, 'app/controllers/probe_controller.rb')).to have_attributes(size: 1)
      expect(Gates.account_kind_violations(snippet, 'lib/probe.rb')).to have_attributes(size: 1)
      expect(Gates.account_kind_violations(snippet, 'spec/factories/accounts.rb')).to be_empty
      expect(Gates.account_kind_violations(snippet, 'config/probe.rb')).to be_empty
    end

    # An allowlist entry exempts the expression it names and nothing else —
    # not the file, not the line.
    it 'exempts only the allowlisted expression in the allowlisted file' do
      entry = Gates::ACCOUNT_KIND_ALLOWLIST.first
      exempt = "#{entry.fetch(:snippet)}\n"

      expect(Gates.account_kind_violations(exempt, entry.fetch(:file))).to be_empty
      expect(Gates.account_kind_violations(exempt, 'lib/somewhere_else.rb')).to have_attributes(size: 1)
      expect(Gates.account_kind_violations("#{exempt}Account.create!(name: name)\n", entry.fetch(:file)))
        .to have_attributes(size: 1)
    end

    it 'names the file, the line number and the reason' do
      violation = Gates.account_kind_violations("x = 1\nAccount.create!(name: name)\n", 'lib/probe.rb').sole

      expect(violation).to eq('lib/probe.rb:2: Account.create!(name: name) [account_kind: is missing]')
    end

    # Every allowlisted snippet still has to be in the file it is pinned to:
    # an entry left behind after the code moved would silently exempt nothing
    # while looking like it exempts something.
    it 'pins every allowlist entry to a snippet that is really there, with a written reason' do
      Gates::ACCOUNT_KIND_ALLOWLIST.each do |entry|
        path = Rails.root.join(entry.fetch(:file))

        expect(path).to exist, entry.fetch(:file)
        expect(path.read).to include(entry.fetch(:snippet)), entry.fetch(:file)
        expect(entry.fetch(:reason)).to be_present
      end
    end
  end

  describe 'the tree it guards' do
    it 'is green: every account created in app/ or lib/ names its kind' do
      expect(Gates.account_kind_failures).to be_empty
    end

    it 'is wired into gates:all' do
      expect(Rake::Task.task_defined?('gates:account_kind')).to be(true)
      expect(Rails.root.join('lib/tasks/gates.rake').read).to include("Rake::Task['gates:account_kind'].invoke")
    end
  end
end
# rubocop:enable RSpec/DescribeClass
