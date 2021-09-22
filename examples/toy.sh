SHELL=sh
echo toy.md | entr -s '\
    zangle ls toy.md --list-tags \
    | grep doctest \
    | while read l; \
        do zangle call toy.md "--tag=${l}" > /tmp/doctest.c; \
           echo -e "\x1b[1mrunning ${l}\x1b[0m"; \
           zig cc -fsanitize=undefined -std=c11 -o /tmp/doctest -Wall -Werror -Wextra /tmp/doctest.c; \
           timeout 10 /tmp/doctest || (echo -e "\x1b[31mTest [${l}] failed with exit code $?\x1b[0m" && break); \
           cp /tmp/doctest.c /tmp/diff.c; \
           clang-format -i /tmp/diff.c --style=WebKit; \
           diff /tmp/doctest.c /tmp/diff.c --color=always; \
        done'
