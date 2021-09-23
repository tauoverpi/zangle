# Toy CPU

    lang: c esc: [[]] tag: #project imports
    ---------------------------------------

    #include <assert.h>
    #include <errno.h>
    #include <stdint.h>
    #include <stdio.h>
    #include <stdlib.h>
    #include <string.h>

    #define CONCAT_(X, Y) X##Y
    #define CONCAT(X, Y) CONCAT_(X, Y)
    #define CONCAT3(X, Y, Z) CONCAT(CONCAT(X, Y), Z)
    #define CONCAT4(X, Y, Z, W) CONCAT(CONCAT(CONCAT(X, Y), Z), W)

    #ifdef _DEBUG
    #define DBG(scope, fmt, ...) fprintf(stderr, "debug(" scope "): " fmt "\n", __VA_ARGS__)
    #define ERR(scope, fmt, ...) fprintf(stderr, "error(" scope "): " fmt "\n", __VA_ARGS__)
    #else
    #define DBG(scope, fmt, ...)
    #define ERR(scope, fmt, ...)
    #endif

    #define container_of(ptr, sample, member) \
        (__typeof__(sample))((char*)(ptr)-offsetof(__typeof__(*sample), member))

    void panic(const char* msg)
    {
        fputs("Panic! ", stderr);
        fputs(msg, stderr);
        fputs("\n", stderr);
        abort();
    }

## Registers

    lang: c esc: none tag: #declare x86-style overlapping registers
    ---------------------------------------------------------------

    typedef struct {
        union {
            uint32_t eax;
            uint16_t ax;
            struct {
                uint8_t al;
                uint8_t ah;
            };
        };

        union {
            uint32_t ebx;
            uint16_t bx;
            struct {
                uint8_t bl;
                uint8_t bh;
            };
        };

        union {
            uint32_t ecx;
            uint16_t cx;
            struct {
                uint8_t cl;
                uint8_t ch;
            };
        };

        union {
            uint32_t edx;
            uint16_t dx;
            struct {
                uint8_t dl;
                uint8_t dh;
            };
        };

        uint32_t ip;

        arraylist_t(uint8_t) stack;
    } machine_t;

<!-- -->

    lang: c esc: [[]] tag: #doctest register overlap
    ------------------------------------------------

    [[project imports]]

    [[data structure library]]

    slice_impl_t(uint8_t);
    arraylist_impl_t(uint8_t);

    [[declare x86-style overlapping registers]]

    int main(void)
    {
        machine_t m = { .eax = 0xdeadbeef };
        assert(m.eax == 0xdeadbeef);
        assert(m.ax == 0xbeef);
        assert(m.ah == 0xbe);
        assert(m.al == 0xef);
        return 0;
    }

# Interpreter

    lang: c esc: none tag: #interpreter opcodes
    -------------------------------------------

    typedef enum {
        OPCODE_HALT, // stop execution
        OPCODE_ADD,  // add
        OPCODE_SUB,  // subtract
        OPCODE_MUL,  // unsigned multiplication
        OPCODE_IMUL, // signed multiplication
        OPCODE_SHL,  // shift left
        OPCODE_SHR,  // shift right
        OPCODE_SAL,  // arithmetic shift left
        OPCODE_SAR,  // arithmetic shift right
        OPCODE_MOV,  // move
        OPCODE_CALL, // call upon a procedure
        OPCODE_JMP,  // unconditional jump
        OPCODE_JNZ,  // jump if not zero
        OPCODE_JZ,   // jump if zero
        OPCODE_JE,   // jump if equal
        OPCODE_JNE,  // jump if not equal
    } opcode_t;

    static_assert(sizeof(opcode_t) == 1);

## Opcode listing

    lang: c esc: [[]] tag: #interpreter
    -----------------------------------

    [[interpreter opcodes]]

    typedef struct {
        OpCode code;
        union {

        };
    } instruction_t;

    static_assert(sizeof(instruction_t) == 4);

    int step(machine_t *m, const instruction_t *program) {
        switch (op.code) {
            case OPCODE_HALT: return 0;

            case OPCODE_ADD: {
                break;
            }

            case OPCODE_SUB: {
                break;
            }

            default: panic("invalid instruction");
        }

        return 1;
    }

# Parser

    lang: c esc: none tag: #tokenizer
    ---------------------------------

    typedef enum {
        TOKEN_SPACE,
        TOKEN_LABEL,
        TOKEN_WORD,
        TOKEN_NL,
        TOKEN_COMMA,
        TOKEN_L_BRACKET,
        TOKEN_R_BRACKET,
        TOKEN_EOF,
        TOKEN_COMMENT,
        TOKEN_HEX_LITERAL,
        TOKEN_DECIMAL_LITERAL,
        TOKEN_INVALID,
    } token_tag_t;

    uint8_t* token_tag_t_name[] = {
        (uint8_t*)&"space",
        (uint8_t*)&"label",
        (uint8_t*)&"word",
        (uint8_t*)&"nl",
        (uint8_t*)&"comma",
        (uint8_t*)&"l_bracket",
        (uint8_t*)&"r_bracket",
        (uint8_t*)&"eof",
        (uint8_t*)&"comment",
        (uint8_t*)&"hex literal",
        (uint8_t*)&"decimal literal",
        (uint8_t*)&"invalid",
    };

    typedef enum {
        TOKENIZER_START,
        TOKENIZER_WORD,
        TOKENIZER_TRIVIAL,
        TOKENIZER_DIGIT,
        TOKENIZER_DECIMAL,
        TOKENIZER_HEX,
        TOKENIZER_COMMENT,
    } tokenizer_state_t;

    uint8_t* tokenizer_state_t_name[] = {
        (uint8_t*)&"start",
        (uint8_t*)&"word",
        (uint8_t*)&"trivial",
        (uint8_t*)&"digit",
        (uint8_t*)&"decimal",
        (uint8_t*)&"hex",
        (uint8_t*)&"comment",
    };

    typedef struct {
        token_tag_t tag;
        size_t start;
        size_t end;
    } token_t;

    typedef struct {
        text_t text;
        size_t index;
    } tokenizer_t;

    slice_t(uint8_t) token_slice(token_t token, text_t text)
    {
        assert(token.start <= token.end);
        assert(token.end < text.len);
        text_t copy = text;
        copy.ptr += token.start;
        copy.len = token.end - token.start;
        return copy;
    }

    token_t tokenizer_next(tokenizer_t* self)
    {
        token_t token;
        token.tag = TOKEN_EOF;
        token.start = self->index;

        tokenizer_state_t state = TOKENIZER_START;
        uint8_t trivial = 0;

        for (; self->index < self->text.len; self->index++) {
            uint8_t c = self->text.ptr[self->index];
            if (c == 0) {
                break;
            }
            DBG("tokenizer", "state %s %c", tokenizer_state_t_name[state], c);

    #define range(FROM, TO) (c >= (FROM) && c <= (TO))
    #define is(CH) (c == (CH))

            switch (state) {
            case TOKENIZER_START: {
                if (range('A', 'Z') || range('a', 'z')) {
                    state = TOKENIZER_WORD;
                    token.tag = TOKEN_WORD;
                } else if (range('1', '9')) {
                    state = TOKENIZER_DECIMAL;
                    token.tag = TOKEN_DECIMAL_LITERAL;
                } else if (is('0')) {
                    state = TOKENIZER_DIGIT;
                } else if (is('[')) {
                    token.tag = TOKEN_L_BRACKET;
                    self->index += 1;
                    goto tokenizer_finish;
                } else if (is(']')) {
                    token.tag = TOKEN_R_BRACKET;
                    self->index += 1;
                    goto tokenizer_finish;
                } else if (is(' ')) {
                    state = TOKENIZER_TRIVIAL;
                    trivial = ' ';
                    token.tag = TOKEN_SPACE;
                } else if (is(',')) {
                    token.tag = TOKEN_COMMA;
                    self->index += 1;
                    goto tokenizer_finish;
                } else if (is(';')) {
                    state = TOKENIZER_COMMENT;
                    token.tag = TOKEN_COMMENT;
                } else if (is('\n')) {
                    state = TOKENIZER_TRIVIAL;
                    token.tag = TOKEN_NL;
                } else {
                    DBG("tokenizer", "invalid byte %d", c);
                    token.tag = TOKEN_INVALID;
                    goto tokenizer_finish;
                }
                continue;
            }

            case TOKENIZER_DIGIT: {
                if (is('x')) {
                    state = TOKENIZER_HEX;
                    token.tag = TOKEN_HEX_LITERAL;
                } else if (range('0', '9')) {
                    state = TOKENIZER_DECIMAL;
                    token.tag = TOKEN_DECIMAL_LITERAL;
                }
                continue;
            }

            case TOKENIZER_HEX: {
                if (range('0', '9') || range('a', 'f') || range('A', 'F')) {
                    // skip
                } else {
                    goto tokenizer_finish;
                }
                continue;
            }

            case TOKENIZER_WORD: {
                if (is(':')) {
                    state = TOKENIZER_START;
                    self->index += 1;
                    token.tag = TOKEN_LABEL;
                    goto tokenizer_finish;
                } else if (range('A', 'Z') || range('a', 'z')) {
                    // eat
                } else {
                    token.tag = TOKEN_WORD;
                    goto tokenizer_finish;
                }
                continue;
            }

            case TOKENIZER_DECIMAL: {
                if (range('0', '9')) {
                    // eat
                } else {
                    goto tokenizer_finish;
                }
                continue;
            }

            case TOKENIZER_COMMENT: {
                if (is('\n')) {
                    goto tokenizer_finish;
                }
                continue;
            }

            case TOKENIZER_TRIVIAL: {
                if (trivial != c) {
                    goto tokenizer_finish;
                } else {
                    continue;
                }
            }

            default:
                panic("invalid tokenizer state!");
            }

    #undef range
    #undef is
        }

    tokenizer_finish:

        token.end = self->index;
        DBG("tokenizr", "returning token %s len %ld", token_tag_t_name[token.tag], token.end - token.start);
        return token;
    }

<!-- -->

    lang: c esc: [[]] tag: #doctest tokenizer
    -----------------------------------------

    [[project imports]]

    [[data structure library]]

    [[project type definitions]]

    [[tokenizer]]

    int main(void)
    {
        {
            tokenizer_t it = { .text = slice_make_const(uint8_t, "label:") };
            assert(tokenizer_next(&it).tag == TOKEN_LABEL);
            assert(tokenizer_next(&it).tag == TOKEN_EOF);
        }
        {
            tokenizer_t it = { .text = slice_make_const(uint8_t, "0x552a") };
            assert(tokenizer_next(&it).tag == TOKEN_HEX_LITERAL);
            assert(tokenizer_next(&it).tag == TOKEN_EOF);
        }
        {
            tokenizer_t it = { .text = slice_make_const(uint8_t, "552") };
            assert(tokenizer_next(&it).tag == TOKEN_DECIMAL_LITERAL);
            assert(tokenizer_next(&it).tag == TOKEN_EOF);
        }
        {
            tokenizer_t it = { .text = slice_make_const(uint8_t, "[eax]") };
            assert(tokenizer_next(&it).tag == TOKEN_L_BRACKET);
            assert(tokenizer_next(&it).tag == TOKEN_WORD);
            assert(tokenizer_next(&it).tag == TOKEN_R_BRACKET);
            assert(tokenizer_next(&it).tag == TOKEN_EOF);
        }
        {
            tokenizer_t it = { .text = slice_make_const(uint8_t, "mov ebx, eax") };
            assert(tokenizer_next(&it).tag == TOKEN_WORD);
            assert(tokenizer_next(&it).tag == TOKEN_SPACE);
            assert(tokenizer_next(&it).tag == TOKEN_WORD);
            assert(tokenizer_next(&it).tag == TOKEN_COMMA);
            assert(tokenizer_next(&it).tag == TOKEN_SPACE);
            assert(tokenizer_next(&it).tag == TOKEN_WORD);
            assert(tokenizer_next(&it).tag == TOKEN_EOF);
        }
        {
            tokenizer_t it = { .text = slice_make_const(uint8_t, "eax;foo\neax") };
            assert(tokenizer_next(&it).tag == TOKEN_WORD);
            assert(tokenizer_next(&it).tag == TOKEN_COMMENT);
            assert(tokenizer_next(&it).tag == TOKEN_NL);
            assert(tokenizer_next(&it).tag == TOKEN_WORD);
            assert(tokenizer_next(&it).tag == TOKEN_EOF);
        }
        return 0;
    }

<!-- -->

    lang: c esc: none tag: #project type definitions
    ------------------------------------------------

    slice_impl_t(uint8_t);
    slice_impl_t(uint32_t);
    arraylist_impl_t(uint32_t);
    optional_impl_t(uint32_t);
    optional_impl_t(arraylist_t(uint32_t));
    optional_impl_t(slice_t(uint8_t));
    fnv1a_impl(uint8_t);
    djb2_impl(uint8_t);
    hashmap_impl_t(slice_t(uint8_t), uint32_t);
    hashmap_impl_t(slice_t(uint8_t), arraylist_t(uint32_t));

    #define text_t slice_t(uint8_t)
    #define location_t arraylist_t(uint32_t)
    #define labelmap_t hashmap_t(text_t, uint32_t)
    #define symbolmap_t hashmap_t(text_t, location_t)
    #define labelmap_contains(MAP, KEY) hashmap_contains(MAP, text_t, uint32_t, KEY)
    #define labelmap_put(MAP, KEY, VAL) hashmap_put(MAP, text_t, uint32_t, KEY, VAL)

<!-- -->

    lang: c esc: none tag: #parser
    ------------------------------

    uint8_t mov_symbol_name[3] = "mov";

    typedef struct {
        symbolmap_t symbols;
        labelmap_t labels;
    } object_t;
    optional_impl_t(object_t);

    int parse(text_t text)
    {
        optional_t(labelmap_t) labels = hashmap_init(text_t, uint32_t, 5);
        optional_t(symbolmap_t) symbols = hashmap_init(text_t, location_t, 5);
        (void)labels;
        (void)symbols;

        tokenizer_t it = { .text = text };

        token_t token = tokenizer_next(&it);
        for (; token.tag != TOKEN_EOF; token = tokenizer_next(&it)) {
            DBG("parser", "starting with %s", token_tag_t_name[token.tag]);

            switch (token.tag) {
            case TOKEN_LABEL: {
                text_t label = token_slice(token, text);
                if (labelmap_contains(&labels.some, label)) {
                    panic("duplicate label");
                }

                if (labelmap_put(&labels.some, label, 0) != 0) {
                    panic("failed to insert");
                }

                continue;
            }

            case TOKEN_WORD: {
                optional_t(text_t) arg1 = optional_none(text_t);
                optional_t(text_t) arg2 = optional_none(text_t);

                text_t instr = token_slice(token, text);
                uint32_t hash = fnv1a(uint8_t, instr);

                int is_memory_reference = 0;

                token = tokenizer_next(&it);
                DBG("parser", "next token is %s", token_tag_t_name[token.tag]);

                if (token.tag == TOKEN_SPACE) {
                    DBG("parser", "skipping %s", token_tag_t_name[token.tag]);
                    token = tokenizer_next(&it);
                }

                // [register]
                if (token.tag == TOKEN_L_BRACKET) {
                    DBG("parser", "arg1 memory reference %x", hash);
                    is_memory_reference = 1;
                    token = tokenizer_next(&it);
                    if (token.tag != TOKEN_WORD) {
                        panic("TODO: error not a word");
                    }

                    arg1 = optional_some(text_t, token_slice(token, text));

                    token = tokenizer_next(&it);
                    if (token.tag != TOKEN_R_BRACKET) {
                        panic("TODO: error not a ]");
                    }

                    token = tokenizer_next(&it);
                    if (token.tag == TOKEN_SPACE) {
                        token = tokenizer_next(&it);
                    }
                } else if (token.tag == TOKEN_WORD) {
                    DBG("parser", "arg1 register argument %x", hash);
                    arg1 = optional_some(text_t, token_slice(token, text));
                    token = tokenizer_next(&it);
                }

                if (token.tag == TOKEN_COMMA) {
                    DBG("parser", "binary instruction %x", hash);
                    token = tokenizer_next(&it);

                    if (token.tag == TOKEN_SPACE) {
                        token = tokenizer_next(&it);
                    }

                    // [register]
                    if (token.tag == TOKEN_L_BRACKET) {
                        DBG("parser", "arg2 memory reference %x", hash);
                        if (is_memory_reference) {
                            panic("TODO: cannot have two memory ref arguments");
                        }

                        is_memory_reference = 1;

                        token = tokenizer_next(&it);
                        if (token.tag != TOKEN_WORD) {
                            panic("TODO: arg2 not a word");
                        }

                        arg2 = optional_some(text_t, token_slice(token, text));

                        token = tokenizer_next(&it);
                        if (token.tag != TOKEN_R_BRACKET) {
                            panic("TODO: arg2 not a ]");
                        }
                    } else if (token.tag == TOKEN_WORD) {
                        DBG("parser", "arg2 register argument %x", hash);
                        arg2 = optional_some(text_t, token_slice(token, text));
                        token = tokenizer_next(&it);
                    }
                } else {
                    DBG("parser", "unary instruction %x", hash);
                }

                switch (hash) {
                case FNV1A("mov"): {
                    DBG("parser", "emitting mov %d", 0);
                    continue;
                }

                case FNV1A("add"): {
                    panic("add");
                }

                case FNV1A("halt"): {
                    DBG("parser", "emitting halt %d", 0);
                    continue;
                }

                default:
                    panic("TODO: handle unknown instructions");
                }
                panic("TODO: more instructions");
            }

            case TOKEN_SPACE:
            case TOKEN_NL: {
                continue;
            }

            case TOKEN_EOF: {
                goto parser_finish;
            }

            default:
                panic("invalid parser state!");
            }
        }

    parser_finish:

        return 0;
    }

<!-- -->

    lang: c esc: [[]] tag: #doctest parser
    --------------------------------------

    [[project imports]]

    [[data structure library]]

    [[project type definitions]]

    [[tokenizer]]
    [[parser]]

    int main(void)
    {
        uint8_t program[] = "label:\n"
                            "    mov eax, ebx\n"
                            "    halt\n";
        assert(parse(slice_make_const(uint8_t, program)) == 0);
        return 0;
    }

# Data structures

    lang: c esc: [[]] tag: #data structure library
    ----------------------------------------------

    [[slice implementation]]
    [[optional implementation]]
    [[array list implementation]]
    [[hash functions library]]
    [[hashmap implementation]]

## Slice

    lang: c esc: none tag: #slice implementation
    --------------------------------------------

    #define slice_t(T) CONCAT(slice_, T)
    #define slice_as_bytes(T, slice)  \
        CONCAT3(slice_, T, _as_bytes) \
        (slice)
    #define slice_eql(T, a, b)   \
        CONCAT3(slice_, T, _eql) \
        (a, b)
    #define slice_make_const(T, arr) \
        (slice_t(T))                 \
        {                            \
            .ptr = (T*)arr,          \
            .len = sizeof(arr)       \
        }

    #define slice_impl_as_bytes(T)                                       \
        slice_t(uint8_t) CONCAT3(slice_, T, _as_bytes)(slice_t(T) slice) \
        {                                                                \
            slice_t(uint8_t) result = {};                                \
            result.ptr = (uint8_t*)slice.ptr;                            \
            result.len = slice.len * sizeof(T);                          \
            return result;                                               \
        }

    #define slice_impl_eql(T)                                    \
        int CONCAT3(slice_, T, _eql)(slice_t(T) a, slice_t(T) b) \
        {                                                        \
            if (a.len != b.len) {                                \
                return 0;                                        \
            }                                                    \
            for (size_t index = 0; index < a.len; index++) {     \
                if (a.ptr[index] != b.ptr[index]) {              \
                    return 0;                                    \
                }                                                \
            }                                                    \
            return 1;                                            \
        }

    #define slice_impl_t(T)  \
        typedef struct {     \
            size_t len;      \
            T* ptr;          \
        } CONCAT(slice_, T); \
        slice_impl_eql(T);   \
        slice_impl_as_bytes(T);

## Optional

    lang: c esc: none tag: #optional implementation
    -----------------------------------------------

    #define optional_t(T) CONCAT(optional_, T)
    #define optional_some(T, value) \
        (optional_t(T))             \
        {                           \
            .some = value,          \
            .none = 0               \
        }
    #define optional_none(T) \
        (optional_t(T))      \
        {                    \
            .none = 1        \
        }
    #define optional_impl_t(T) \
        typedef struct {       \
            T some;            \
            uint8_t none;      \
        } CONCAT(optional_, T);

## Array list

    lang: c esc: none tag: #array list implementation
    -------------------------------------------------

    #define arraylist_t(T) CONCAT(arraylist_, T)
    #define arraylist_append(self, T, item) \
        CONCAT3(arraylist_, T, _append)     \
        (self, item)
    #define arraylist_pop(self, T)   \
        CONCAT3(arraylist_, T, _pop) \
        (self)
    #define arraylist_deinit(self, T)   \
        CONCAT3(arraylist_, T, _deinit) \
        (self)
    #define arraylist_slice(self, T, from, to) \
        CONCAT3(arraylist_, T, _slice)         \
        (self, from, to)

    #define arraylist_impl_slice(T)                                                                \
        slice_t(T) CONCAT3(arraylist_, T, _slice)(arraylist_t(T) * self, size_t start, size_t end) \
        {                                                                                          \
            assert(start <= end);                                                                  \
            assert(start <= self->len);                                                            \
            assert(end <= self->len);                                                              \
            slice_t(T) slice = {};                                                                 \
            slice.ptr = self->ptr + start;                                                         \
            slice.len = end - start;                                                               \
            return slice;                                                                          \
        }

    #define arraylist_impl_deinit(T)                                \
        void CONCAT3(arraylist_, T, _deinit)(arraylist_t(T) * self) \
        {                                                           \
            assert(self->ptr != NULL);                              \
            free(self->ptr);                                        \
            self->ptr = NULL;                                       \
            self->capacity = 0;                                     \
            self->len = 0;                                          \
        }

    #define arraylist_impl_pop(T)                                     \
        T CONCAT3(arraylist_, T, _pop)(arraylist_t(T) * self)         \
        {                                                             \
            assert(self->len != 0);                                   \
            self->len -= 1;                                           \
            DBG("arraylist", "removed item at index %lu", self->len); \
            return self->ptr[self->len];                              \
        }

    #define arraylist_impl_append(T)                                                                                \
        int CONCAT3(arraylist_, T, _append)(arraylist_t(T) * self, T item)                                          \
        {                                                                                                           \
            if (self->ptr == NULL) {                                                                                \
                assert(self->capacity == 0);                                                                        \
                assert(self->len == 0);                                                                             \
                self->ptr = calloc(8, sizeof(T));                                                                   \
                if (self->ptr == NULL) {                                                                            \
                    return -1;                                                                                      \
                }                                                                                                   \
                self->capacity = 8;                                                                                 \
                DBG("arraylist", "initialized with capacity %ld", self->capacity);                                  \
            } else if (self->capacity - self->len == 0) {                                                           \
                assert(self->ptr != NULL);                                                                          \
                size_t new_capacity = self->capacity / 2 + 8;                                                       \
                T* new = realloc(self->ptr, new_capacity * sizeof(T));                                              \
                if (new == NULL) {                                                                                  \
                    return -1;                                                                                      \
                }                                                                                                   \
                memset(new + self->capacity, 0, new_capacity - self->capacity);                                     \
                self->ptr = new;                                                                                    \
                self->capacity = new_capacity;                                                                      \
                DBG("arraylist", "expanded to capacity %ld, free %ld", self->capacity, self->capacity - self->len); \
            }                                                                                                       \
                                                                                                                    \
            DBG("arraylist", "inserting item at index %ld", self->len);                                             \
            self->ptr[self->len] = item;                                                                            \
            self->len += 1;                                                                                         \
            return 0;                                                                                               \
        }

    #define arraylist_impl_t(T)   \
        typedef struct {          \
            size_t len;           \
            size_t capacity;      \
            T* ptr;               \
        } CONCAT(arraylist_, T);  \
        arraylist_impl_append(T); \
        arraylist_impl_pop(T);    \
        arraylist_impl_deinit(T); \
        arraylist_impl_slice(T);

<!-- -->

    lang: c esc: [[]] tag: #doctest array list append
    -------------------------------------------------

    [[project imports]]

    [[data structure library]]

    slice_impl_t(uint8_t);
    arraylist_impl_t(uint8_t);

    int main(void)
    {
        arraylist_t(uint8_t) list = {};
        arraylist_append(&list, uint8_t, 5);
        assert(list.len == 1);
        arraylist_append(&list, uint8_t, 6);
        assert(list.len == 2);
        arraylist_append(&list, uint8_t, 7);
        assert(list.len == 3);

        assert(list.ptr[0] == 5);
        assert(list.ptr[1] == 6);
        assert(list.ptr[2] == 7);

        slice_t(uint8_t) slice = arraylist_slice(&list, uint8_t, 0, list.len);
        assert(slice.ptr[0] == 5);
        assert(slice.ptr[1] == 6);
        assert(slice.ptr[2] == 7);

        assert(arraylist_pop(&list, uint8_t) == 7);
        assert(arraylist_pop(&list, uint8_t) == 6);
        assert(arraylist_pop(&list, uint8_t) == 5);

        assert(list.len == 0);

        arraylist_deinit(&list, uint8_t);

        assert(list.ptr == NULL);
        assert(list.capacity == 0);

        return 0;
    }

## Hash functions

    lang: c esc: [[]] tag: #hash functions library
    ----------------------------------------------

    [[fnv1a implementation]]
    [[djb2 implementation]]

### FNV-1a

    lang: c esc: none tag: #fnv1a implementation
    --------------------------------------------

    #define FNV_32_BIT_PRIME (uint32_t)16777619
    #define FNV_32_BIT_OFFSET (uint32_t)2166136261
    #define FNV1A_0(BYTE, P) ((uint32_t)((BYTE ^ (P)) * FNV_32_BIT_PRIME))
    #define FNV1A_2(S, P) (FNV1A_0(S[1], FNV1A_0(S[0], P)))
    #define FNV1A_4(S, P) (FNV1A_0(S[3], FNV1A_0(S[2], FNV1A_2(S, P))))
    #define FNV1A_6(S, P) (FNV1A_0(S[5], FNV1A_0(S[4], FNV1A_4(S, P))))
    #define FNV1A(S)                                                              \
        ((uint32_t)(sizeof(S) == 1 ? FNV1A_0(S[0], FNV_32_BIT_OFFSET)             \
                : sizeof(S) == 2   ? FNV1A_0(S[0], FNV_32_BIT_OFFSET)             \
                : sizeof(S) == 3   ? FNV1A_2(S, FNV_32_BIT_OFFSET)                \
                : sizeof(S) == 4   ? FNV1A_0(S[2], FNV1A_2(S, FNV_32_BIT_OFFSET)) \
                : sizeof(S) == 5   ? FNV1A_4(S, FNV_32_BIT_OFFSET)                \
                : sizeof(S) == 6   ? FNV1A_0(S[4], FNV1A_4(S, FNV_32_BIT_OFFSET)) \
                : sizeof(S) == 7   ? FNV1A_6(S, FNV_32_BIT_OFFSET)                \
                                   : -1))

    #define fnv1a(T, slice) \
        CONCAT(fnv1a_, T)   \
        (slice)

    #define fnv1a_impl(T)                                        \
        uint32_t CONCAT(fnv1a_, T)(slice_t(T) slice)             \
        {                                                        \
            slice_t(uint8_t) bytes = slice_as_bytes(T, slice);   \
                                                                 \
            uint32_t hash = FNV_32_BIT_OFFSET;                   \
                                                                 \
            for (size_t index = 0; index < bytes.len; index++) { \
                hash ^= bytes.ptr[index];                        \
                hash *= FNV_32_BIT_PRIME;                        \
            }                                                    \
                                                                 \
            return hash;                                         \
        }

<!-- -->

    lang: c esc: [[]] tag: #doctest fnv1a
    -------------------------------------

    [[project imports]]

    [[data structure library]]

    slice_impl_t(uint8_t);
    fnv1a_impl(uint8_t);

    int main(void)
    {
        uint8_t input[12][6] = {
            "3pjNqM",
            "5R0Lg7",
            "7oE486",
            "BR42qf",
            "FouBSr",
            "GkkzFD",
            "HVGZq9",
            "IwPSdT",
            "`nrY3G",
            "qzs0UD",
            "sXbssr",
            "uh4tSI",
        };

        assert(fnv1a(uint8_t, slice_make_const(uint8_t, input[0])) == 0);
        assert(fnv1a(uint8_t, slice_make_const(uint8_t, input[1])) == 0);
        assert(fnv1a(uint8_t, slice_make_const(uint8_t, input[2])) == 0);
        assert(fnv1a(uint8_t, slice_make_const(uint8_t, input[3])) == 0);
        assert(fnv1a(uint8_t, slice_make_const(uint8_t, input[4])) == 0);
        assert(fnv1a(uint8_t, slice_make_const(uint8_t, input[5])) == 0);
        assert(fnv1a(uint8_t, slice_make_const(uint8_t, input[6])) == 0);
        assert(fnv1a(uint8_t, slice_make_const(uint8_t, input[7])) == 0);
        assert(fnv1a(uint8_t, slice_make_const(uint8_t, input[8])) == 0);
        assert(fnv1a(uint8_t, slice_make_const(uint8_t, input[9])) == 0);
        assert(fnv1a(uint8_t, slice_make_const(uint8_t, input[10])) == 0);
        assert(fnv1a(uint8_t, slice_make_const(uint8_t, input[11])) == 0);

        uint8_t a[1] = "a";
        uint8_t ab[2] = "ab";
        uint8_t abc[3] = "abc";
        uint8_t abcd[4] = "abcd";
        uint8_t abcde[5] = "abcde";
        assert(fnv1a(uint8_t, slice_make_const(uint8_t, a)) == FNV1A("a"));
        assert(fnv1a(uint8_t, slice_make_const(uint8_t, ab)) == FNV1A("ab"));
        assert(fnv1a(uint8_t, slice_make_const(uint8_t, abc)) == FNV1A("abc"));
        assert(fnv1a(uint8_t, slice_make_const(uint8_t, abcd)) == FNV1A("abcd"));
        assert(fnv1a(uint8_t, slice_make_const(uint8_t, abcde)) == FNV1A("abcde"));

        return 0;
    }

### DJB2

    lang: c esc: none tag: #djb2 implementation
    -------------------------------------------

    #define djb2(T, slice) \
        CONCAT(djb2_, T)   \
        (slice)

    #define djb2_impl(T)                                         \
        uint32_t CONCAT(djb2_, T)(slice_t(T) slice)              \
        {                                                        \
            slice_t(uint8_t) bytes = slice_as_bytes(T, slice);   \
                                                                 \
            uint64_t hash = 5381;                                \
                                                                 \
            for (size_t index = 0; index < bytes.len; index++) { \
                hash = ((hash << 5) + hash) ^ bytes.ptr[index];  \
            }                                                    \
                                                                 \
            return hash;                                         \
        }

<!-- -->


    lang: c esc: [[]] tag: #doctest djb2
    ------------------------------------

    [[project imports]]

    [[data structure library]]

    slice_impl_t(uint8_t);
    djb2_impl(uint8_t);

    int main(void)
    {
        uint8_t input2[1][2] = { "Ez" };
        assert(djb2(uint8_t, slice_make_const(uint8_t, input2[0])) == 5861786);
        return 0;
    }

## Hashmap

    lang: c esc: none tag: #hashmap implementation
    ----------------------------------------------

    #define hashmap_t(K, V) CONCAT3(hashmap_, K, V)
    #define hashmap_init(K, V, size)   \
        CONCAT4(hashmap_, K, V, _init) \
        (size)
    #define hashmap_deinit(self, K, V)   \
        CONCAT4(hashmap_, K, V, _deinit) \
        (self)
    #define hashmap_get(self, K, V, key) \
        CONCAT4(hashmap_, K, V, _get)    \
        (self, key)
    #define hashmap_contains(self, K, V, key) \
        CONCAT4(hashmap_, K, V, _contains)    \
        (self, key)
    #define hashmap_put(self, K, V, key, value) \
        CONCAT4(hashmap_, K, V, _put)           \
        (self, key, value)

    #ifndef MAX_CUCKOO_RELOCATIONS
    #define MAX_CUCKOO_RELOCATIONS 32
    #endif

    #define fingerprint(T, x) fnv1a(uint8_t, slice_as_bytes(T, x))
    #define hash(T, x, capacity) (djb2(T, x) & (capacity - 1))

    #define hashmap_impl_deinit(K, V)                                 \
        void CONCAT4(hashmap_, K, V, _deinit)(hashmap_t(K, V) * self) \
        {                                                             \
            self->capacity = 0;                                       \
            free(self->slot);                                         \
            free(self->bucket);                                       \
            self->slot = NULL;                                        \
            self->bucket = NULL;                                      \
        }

    #define hashmap_impl_init(K, V)                                              \
        optional_t(hashmap_t(K, V)) CONCAT4(hashmap_, K, V, _init)(uint8_t size) \
        {                                                                        \
            hashmap_t(K, V) map;                                                 \
            size_t capacity = ((size_t)2) << size;                               \
            DBG("hashmap", "initializing hashmap with capacity %ld", capacity);  \
            map.slot = calloc(capacity, sizeof(uint32_t));                       \
            if (map.slot == NULL) {                                              \
                ERR("hashmap", "failed allocating %ld slots", capacity);         \
                return optional_none(hashmap_t(K, V));                           \
            }                                                                    \
                                                                                 \
            map.bucket = calloc(capacity, sizeof(uint32_t));                     \
            if (map.bucket == NULL) {                                            \
                ERR("hashmap", "failed allocating %ld buckets", capacity);       \
                free(map.slot);                                                  \
                return optional_none(hashmap_t(K, V));                           \
            }                                                                    \
                                                                                 \
            map.capacity = capacity;                                             \
                                                                                 \
            return optional_some(hashmap_t(K, V), map);                          \
        }

    #define hashmap_impl_put(K, V)                                                           \
        int CONCAT4(hashmap_, K, V, _put)(hashmap_t(K, V) * self, K key, V value)            \
        {                                                                                    \
            uint32_t f = fingerprint(uint8_t, key);                                          \
            uint32_t i1 = hash(uint8_t, key, self->capacity);                                \
            slice_t(uint32_t) tmp = { .ptr = &f, .len = 1 };                                 \
            uint32_t i2 = i1 ^ hash(uint8_t, slice_as_bytes(uint32_t, tmp), self->capacity); \
                                                                                             \
            DBG("hashmap", "fingerprint %x (put)", f);                                       \
            DBG("hashmap", "i1          %x", i1);                                            \
            DBG("hashmap", "i2          %x", i2);                                            \
                                                                                             \
            if (self->slot[i1] == 0) {                                                       \
                DBG("hashmap", "slot 1 free %x", i1);                                        \
                self->slot[i1] = f;                                                          \
                self->bucket[i1] = value;                                                    \
                return 0;                                                                    \
            }                                                                                \
                                                                                             \
            if (self->slot[i2] == 0) {                                                       \
                DBG("hashmap", "slot 2 free %x", i2);                                        \
                self->slot[i2] = f;                                                          \
                self->bucket[i2] = value;                                                    \
                return 0;                                                                    \
            }                                                                                \
                                                                                             \
            uint32_t i = f & 1 ? i1 : i2;                                                    \
                                                                                             \
            DBG("hashmap", "no free slot selecting %x", i);                                  \
                                                                                             \
            V v_current = value;                                                             \
            uint32_t f_current;                                                              \
                                                                                             \
            for (size_t relo = 0; relo < MAX_CUCKOO_RELOCATIONS; relo++) {                   \
                V v_tmp = self->bucket[i];                                                   \
                uint32_t f_tmp = self->slot[i];                                              \
                                                                                             \
                DBG("hashmap", "kicking out %x and inserting %x", f_tmp, f_current);         \
                                                                                             \
                self->bucket[i] = v_current;                                                 \
                self->slot[i] = f_current;                                                   \
                                                                                             \
                f_current = f_tmp;                                                           \
                v_current = v_tmp;                                                           \
                                                                                             \
                i ^= hash(uint8_t, slice_as_bytes(uint32_t, tmp), self->capacity);           \
                                                                                             \
                if (self->slot[i] == 0) {                                                    \
                    DBG("hashmap", "empty slot %x found, inserting %x", i, f_current);       \
                    self->slot[i] = f_current;                                               \
                    self->bucket[i] = v_current;                                             \
                    return 0;                                                                \
                }                                                                            \
            }                                                                                \
                                                                                             \
            ERR("hashmap", "no free slots found, failed inserting %x", f_current);           \
            return -1;                                                                       \
        }

    #define hashmap_impl_get_ptr(K, V)                                                                           \
        typedef V* CONCAT4(hashmap_, K, V, _p);                                                                  \
        optional_impl_t(CONCAT4(hashmap_, K, V, _p));                                                            \
        optional_t(CONCAT4(hashmap_, K, V, _p)) CONCAT4(hashmap_, K, V, _get_ptr)(hashmap_t(K, V) * self, K key) \
        {                                                                                                        \
            uint32_t f = fingerprint(uint8_t, key);                                                              \
            uint32_t i1 = hash(uint8_t, key, self->capacity);                                                    \
            slice_t(uint32_t) tmp = { .ptr = &f, .len = 1 };                                                     \
            uint32_t i2 = i1 ^ hash(uint8_t, slice_as_bytes(uint32_t, tmp), self->capacity);                     \
                                                                                                                 \
            DBG("hashmap", "fingerprint %x (get ptr)", f);                                                       \
            DBG("hashmap", "i1          %x", i1);                                                                \
            DBG("hashmap", "i2          %x", i2);                                                                \
                                                                                                                 \
            if (self->slot[i1] == f) {                                                                           \
                DBG("hashmap", "found in slot 1 (%x)", i1);                                                      \
                return optional_some(CONCAT4(hashmap_, K, V, _p), &self->bucket[i1]);                            \
            }                                                                                                    \
                                                                                                                 \
            if (self->slot[i2] == f) {                                                                           \
                DBG("hashmap", "found in slot 2 (%x)", i2);                                                      \
                return optional_some(CONCAT4(hashmap_, K, V, _p), &self->bucket[i2]);                            \
            }                                                                                                    \
                                                                                                                 \
            DBG("hashmap", "entry %x not found", f);                                                             \
            return optional_none(CONCAT4(hashmap_, K, V, _p));                                                   \
        }

    #define hashmap_impl_contains(K, V)                                                      \
        int CONCAT4(hashmap_, K, V, _contains)(hashmap_t(K, V) * self, K key)                \
        {                                                                                    \
            uint32_t f = fingerprint(uint8_t, key);                                          \
            uint32_t i1 = hash(uint8_t, key, self->capacity);                                \
            slice_t(uint32_t) tmp = { .ptr = &f, .len = 1 };                                 \
            uint32_t i2 = i1 ^ hash(uint8_t, slice_as_bytes(uint32_t, tmp), self->capacity); \
                                                                                             \
            DBG("hashmap", "fingerprint %x (contains)", f);                                  \
            DBG("hashmap", "i1          %x", i1);                                            \
            DBG("hashmap", "i2          %x", i2);                                            \
                                                                                             \
            if (self->slot[i1] == f) {                                                       \
                DBG("hashmap", "found in slot 1 (%x)", i1);                                  \
                return 1;                                                                    \
            }                                                                                \
                                                                                             \
            if (self->slot[i2] == f) {                                                       \
                DBG("hashmap", "found in slot 2 (%x)", i2);                                  \
                return 1;                                                                    \
            }                                                                                \
                                                                                             \
            DBG("hashmap", "entry %x not found", f);                                         \
            return 0;                                                                        \
        }

    #define hashmap_impl_get(K, V)                                                           \
        optional_t(V) CONCAT4(hashmap_, K, V, _get)(hashmap_t(K, V) * self, K key)           \
        {                                                                                    \
            uint32_t f = fingerprint(uint8_t, key);                                          \
            uint32_t i1 = hash(uint8_t, key, self->capacity);                                \
            slice_t(uint32_t) tmp = { .ptr = &f, .len = 1 };                                 \
            uint32_t i2 = i1 ^ hash(uint8_t, slice_as_bytes(uint32_t, tmp), self->capacity); \
                                                                                             \
            DBG("hashmap", "fingerprint %x (get)", f);                                       \
            DBG("hashmap", "i1          %x", i1);                                            \
            DBG("hashmap", "i2          %x", i2);                                            \
                                                                                             \
            if (self->slot[i1] == f) {                                                       \
                DBG("hashmap", "found in slot 1 (%x)", i1);                                  \
                return optional_some(V, self->bucket[i1]);                                   \
            }                                                                                \
                                                                                             \
            if (self->slot[i2] == f) {                                                       \
                DBG("hashmap", "found in slot 2 (%x)", i2);                                  \
                return optional_some(V, self->bucket[i2]);                                   \
            }                                                                                \
                                                                                             \
            DBG("hashmap", "entry %x not found", f);                                         \
            return optional_none(V);                                                         \
        }

    #define hashmap_impl_remove(K, V)                                                        \
        void CONCAT4(hashmap_, K, V, _remove)(hashmap_t(K, V) * self, K key)                 \
        {                                                                                    \
            uint32_t f = fingerprint(uint8_t, key);                                          \
            uint32_t i1 = hash(uint8_t, key, self->capacity);                                \
            slice_t(uint32_t) tmp = { .ptr = &f, .len = 1 };                                 \
            uint32_t i2 = i1 ^ hash(uint8_t, slice_as_bytes(uint32_t, tmp), self->capacity); \
                                                                                             \
            DBG("hashmap", "fingerprint %x (remove)", f);                                    \
            DBG("hashmap", "i1          %x", i1);                                            \
            DBG("hashmap", "i2          %x", i2);                                            \
                                                                                             \
            if (self->slot[i1] == f) {                                                       \
                DBG("hashmap", "found in slot 1 (%x), removing %x", i1, f);                  \
                self->slot[i1] = 0;                                                          \
            }                                                                                \
                                                                                             \
            if (self->slot[i2] == f) {                                                       \
                DBG("hashmap", "found in slot 2 (%x), removing %x", i2, f);                  \
                self->slot[i2] = 0;                                                          \
            }                                                                                \
                                                                                             \
            DBG("hashmap", "key %x not found", f);                                           \
        }

    #define hashmap_impl_t(K, V)                  \
        typedef struct {                          \
            uint32_t* slot;                       \
            V* bucket;                            \
            size_t capacity;                      \
        } CONCAT3(hashmap_, K, V);                \
        hashmap_impl_remove(K, V);                \
        hashmap_impl_get(K, V);                   \
        hashmap_impl_get_ptr(K, V);               \
        hashmap_impl_contains(K, V);              \
        hashmap_impl_put(K, V);                   \
        optional_impl_t(CONCAT3(hashmap_, K, V)); \
        hashmap_impl_init(K, V);                  \
        hashmap_impl_deinit(K, V);

<!-- -->

    lang: c esc: [[]] tag: #doctest hashmap
    ---------------------------------------

    [[project imports]]

    [[data structure library]]

    slice_impl_t(uint8_t);
    optional_impl_t(uint8_t);
    slice_impl_t(uint32_t);
    fnv1a_impl(uint8_t);
    djb2_impl(uint8_t);
    hashmap_impl_t(slice_t(uint8_t), uint8_t);

    #define string_t slice_t(uint8_t)
    #define map_t hashmap_t(string_t, uint8_t)

    int main(void)
    {
        optional_t(map_t) map = hashmap_init(string_t, uint8_t, 5);
        assert(map.none == 0);
        assert(map.some.capacity != 0);
        assert(map.some.slot != NULL);
        assert(map.some.bucket != NULL);

        optional_t(uint8_t) missing = hashmap_get(&map.some, string_t, uint8_t, slice_make_const(uint8_t, "hello"));
        assert(missing.none == 1);

        assert(hashmap_put(&map.some, string_t, uint8_t, slice_make_const(uint8_t, "hello"), 9) == 0);

        optional_t(uint8_t) result = hashmap_get(&map.some, string_t, uint8_t, slice_make_const(uint8_t, "hello"));
        assert(result.none == 0);
        assert(result.some == 9);

        hashmap_deinit(&map.some, string_t, uint8_t);
        assert(map.some.capacity == 0);
        assert(map.some.slot == NULL);
        assert(map.some.bucket == NULL);

        return 0;
    }

<!-- -->
