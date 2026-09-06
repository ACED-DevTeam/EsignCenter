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
    it 'catches every creation form with no kind named' do
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
        'account.dup',
        'testing_account = account.dup',
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
        'Account.create name: name, account_kind: kind'
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
