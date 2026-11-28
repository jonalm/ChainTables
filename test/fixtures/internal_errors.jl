# An internal error type has no `showerror`, so `@test_throws` matches a fragment against
# its `show` form, where a quote or a `$` of `detail` is escaped. This gives a fragment
# of `detail` in that form.
as_shown(fragment) = chop(repr(fragment); head = 1, tail = 1)
