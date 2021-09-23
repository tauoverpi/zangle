SHELL=sh
echo toy.md | entr -s '\
    zangle tangle toy.md; \
    zangle ls toy.md \
    | grep doctest \
    | while read l; \
        do echo -e "\x1b[1mrunning ${l}\x1b[0m"; \
           zig cc -fsanitize=undefined -std=c11 -o /tmp/doctest -Wall -Werror -Wextra $l; \
           timeout 10 /tmp/doctest || (echo -e "\x1b[31mTest [${l}] failed with exit code $?\x1b[0m"; break); \
           cp $l /tmp/diff.c; \
           clang-format -i /tmp/diff.c --style=WebKit; \
           diff $l /tmp/diff.c --color=always; \
        done'
