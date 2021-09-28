#!/bin/sh

while true
do
    echo README.md \
    | SHELL=/bin/sh entr -s '\
    zangle tangle README.md; \
    ls graphs/ | grep ".dot" | sed "s/.dot\$//" | xargs -I "{}" dot -Tpng -o out/{}.png graphs/{}.dot; \
    ls graphs/ | grep ".uml" | sed "s/.uml\$//" | xargs -I "{}" plantuml -o ../out/ graphs/{}.uml; \
    pandoc README.md -o /tmp/out.pdf \
                        --standalone \
                        --toc \
                        --file-scope \
                        --pdf-engine=xelatex \
                        --highlight-style=misc/syntax.theme \
                        --syntax-definition=misc/syntax.xml \
                        --metadata-file misc/metadata.yml \
                        --indented-code-classes=zig & \
    zig build; \
    zig-out/bin/zangle graph README.md \
        --graph-background-colour="#000000" \
        --graph-inherit-line-colour \
        --graph-text-colour="#ffffff" \
        --graph-border-colour="#444444" | dot -Tpng -o /tmp/zangle.png; \
    zig build test \
        || zig fmt --check --ast-check src lib \
            | while read l; do \
                cp $l /tmp/tmp.zig; \
                zig fmt /tmp/tmp.zig; \
                diff $l /tmp/tmp.zig; \
              done'
    sleep 5
done
