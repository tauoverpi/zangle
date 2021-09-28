# Contributing to zangle 101

1. Fork the master branch
2. Open a draft pull request and link related issues
3. Commit changes while following the commit style guide
4. Mark as ready and await review
5. Upon requested changes: discuss, apply, and so on
6. ????
7. Merged

## Commits

Commits fall into the following categories:

| prefix      | meaning                                                                      |
| --          | --                                                                           |
| `fix:`      | This commit fixes a bug in zangle                                            |
| `doc:`      | This commit improves documentation and involves no functional changes        |
| `ci/cd:`    | This commit only concerns the CI/CD pipeline                                 |
| `chore:`    | This commit contains structural and no functional changes (file rename, ect) |
| `feature:`  | This commit adds a new feature or command to zangle                          |
| `workflow:` | This commit updates or adds workflow scripts for working with zangle         |

Where functional changes should be kept separate from documentation even if
that requires a greater number of commits to document the change.

Each commit should start with it's category prefix (e.g `doc: add description
of opcodes`) and be relatively short message after. More information can be
written after a blank line but usually such is better if it can go in the
document itself.

## Branch / Pull Request names

Branches should have the prefix of their intended change with a prefix
similar to those for commits but with a `-` dash instead of a `:` colon with
the rest of the name using `'` dashes in-place of what would be spaces (e.g
`fix-rendering-indent-in-nested-blocks`).

## License

All code submitted must be under the MIT license of the same version as in
LICENSE and will be taken as such unless specified otherwise. Code under
any other license will be rejected.

## Remember

Append your name and link your github profile in CONTRIBUTORS.md if this
is your first contribution to the project.
