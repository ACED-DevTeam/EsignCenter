# frozen_string_literal: true

# D73 lineage, the whole FAMILY rather than one chain of ancestors. Every copy
# of a document carries the id of the document the family started from, so two
# sibling corrections of the same origin can see each other — walking
# `resubmitted_from_id` upward could not.
#
# Deliberately no foreign key: the root id must survive the permanent deletion
# of the origin, or deleting the original would let a copy be counted a second
# time. `resubmitted_from_id` stays as the audit pointer at the immediate
# origin.
class AddLineageRootToSubmissions < ActiveRecord::Migration[8.1]
  def change
    add_column :submissions, :lineage_root_id, :bigint, null: true

    add_index :submissions, :lineage_root_id, where: 'lineage_root_id IS NOT NULL'

    reversible do |dir|
      dir.up { backfill_lineage_roots }
    end
  end

  # A chain of corrections is never longer than this; past it the walk stops
  # where it is rather than following a cycle forever.
  MAX_HOPS = 50

  # Existing copies point only at their immediate origin: walk each chain up
  # to its oldest ancestor. The whole parent map is read first and every row
  # walks it to the end, so the answer does not depend on ids being in
  # chain order (imported or restored data need not be).
  def backfill_lineage_roots
    ids = Set.new
    parents = {}

    execute('SELECT id, resubmitted_from_id FROM submissions').each do |row|
      ids << row['id'].to_i
      parents[row['id'].to_i] = row['resubmitted_from_id'].to_i if row['resubmitted_from_id']
    end

    roots = {}

    parents.each_key do |id|
      execute("UPDATE submissions SET lineage_root_id = #{root_of(id, parents, roots, ids)} WHERE id = #{id}")
    end
  end

  # The oldest ancestor of `id`: follow parents until a document that has
  # none (the original), a document whose root is already known, a parent
  # that no longer exists, or the hop cap — in every case the last document
  # confirmed PRESENT is the root, never a phantom id. Every document on the
  # way is memoised.
  def root_of(id, parents, roots, ids)
    chain = []
    current = id

    while parents.key?(current) && !roots.key?(current) && chain.size < MAX_HOPS
      parent = parents[current]

      break unless ids.include?(parent)

      chain << current
      current = parent
    end

    root = roots.fetch(current, current)

    chain.each { |member| roots[member] = root }

    root
  end
end
