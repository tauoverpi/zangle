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

    #define container_of(ptr, sample, member) \
        (__typeof__(sample))((char*)(ptr)-offsetof(__typeof__(*sample), member))

    void panic(const char* msg)
    {
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

    lang: c esc: [[]] tag: #doctest parser
    --------------------------------------

    [[project imports]]

    [[data structure library]]

    typedef enum {
        TOKEN_SPACE,
        TOKEN_LABEL,
        TOKEN_WORD,
        TOKEN_NL,
        TOKEN_COMMA,
        TOKEN_L_BRACKET,
        TOKEN_R_BRACKET,
    } token_tag_t;

    int main(void)
    {
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

    #define slice_impl_t(T)  \
        typedef struct {     \
            size_t len;      \
            T* ptr;          \
        } CONCAT(slice_, T); \
        slice_impl_as_bytes(T)

## Optinal

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
            .none = 0        \
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

    #define arraylist_impl_pop(T)                             \
        T CONCAT3(arraylist_, T, _pop)(arraylist_t(T) * self) \
        {                                                     \
            assert(self->len != 0);                           \
            self->len -= 1;                                   \
            return self->ptr[self->len];                      \
        }

    #define arraylist_impl_append(T)                                            \
        int CONCAT3(arraylist_, T, _append)(arraylist_t(T) * self, T item)      \
        {                                                                       \
            if (self->ptr == NULL) {                                            \
                assert(self->capacity == 0);                                    \
                assert(self->len == 0);                                         \
                self->ptr = calloc(8, sizeof(T));                               \
                if (self->ptr == NULL) {                                        \
                    return -1;                                                  \
                }                                                               \
                self->capacity = 8;                                             \
            } else if (self->capacity - self->len == 0) {                       \
                assert(self->ptr != NULL);                                      \
                size_t new_capacity = self->capacity / 2 + 8;                   \
                T* new = realloc(self->ptr, new_capacity * sizeof(T));          \
                if (new == NULL) {                                              \
                    return -1;                                                  \
                }                                                               \
                memset(new + self->capacity, 0, new_capacity - self->capacity); \
                self->ptr = new;                                                \
                self->capacity = new_capacity;                                  \
            }                                                                   \
                                                                                \
            self->ptr[self->len] = item;                                        \
            self->len += 1;                                                     \
            return 0;                                                           \
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

    #define FNV_32_BIT_PRIME 16777619
    #define FNV_32_BIT_OFFSET 2166136261

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

    #ifndef MAX_CUCKOO_RELOCATIONS
    #define MAX_CUCKOO_RELOCATIONS 32
    #endif

    #define fingerprint(T, x) fnv1a(uint8_t, slice_as_bytes(T, x))
    #define hash(T, x, capacity) (djb2(T, x) & (capacity - 1))

    // TODO: select an entry and swap
    #define hashmap_impl_put(K, V)                                                           \
        int CONCAT4(hashmap_, K, V, _put)(hashmap_t(K, V) * self, K key, V value)            \
        {                                                                                    \
            uint32_t f = fingerprint(uint8_t, key);                                          \
            uint32_t i1 = hash(uint8_t, key, self->capacity);                                \
            slice_t(uint32_t) tmp = { .ptr = &f, .len = 1 };                                 \
            uint32_t i2 = i1 ^ hash(uint8_t, slice_as_bytes(uint32_t, tmp), self->capacity); \
                                                                                             \
            if (self->slots[i1] == 0) {                                                      \
                self->slots[i1] = f;                                                         \
                self->buckets[i1] = value;                                                   \
                return 0;                                                                    \
            }                                                                                \
                                                                                             \
            if (self->slots[i2] == 0) {                                                      \
                self->slots[i2] = f;                                                         \
                self->buckets[i2] = value;                                                   \
                return 0;                                                                    \
            }                                                                                \
                                                                                             \
            uint32_t i = f & 1 ? i1 : i2;                                                    \
                                                                                             \
            for (size_t relo = 0; relo < MAX_CUCKOO_RELOCATIONS; relo++) {                   \
                                                                                             \
                i ^= hash(uint8_t, slice_as_bytes(uint32_t, tmp), self->capacity);           \
                                                                                             \
                if (self->slots[i] == 0) {                                                   \
                    self->slots[i] = f;                                                      \
                    self->buckets[i] = value;                                                \
                    return 0;                                                                \
                }                                                                            \
            }                                                                                \
                                                                                             \
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
            if (self->slots[i1] == f) {                                                                          \
                return optional_some(CONCAT4(hashmap_, K, V, _p), &self->buckets[i1]);                           \
            }                                                                                                    \
                                                                                                                 \
            if (self->slots[i2] == f) {                                                                          \
                return optional_some(CONCAT4(hashmap_, K, V, _p), &self->buckets[i2]);                           \
            }                                                                                                    \
                                                                                                                 \
            return optional_none(CONCAT4(hashmap_, K, V, _p));                                                   \
        }

    #define hashmap_impl_get(K, V)                                                           \
        optional_t(V) CONCAT4(hashmap_, K, V, _get)(hashmap_t(K, V) * self, K key)           \
        {                                                                                    \
            uint32_t f = fingerprint(uint8_t, key);                                          \
            uint32_t i1 = hash(uint8_t, key, self->capacity);                                \
            slice_t(uint32_t) tmp = { .ptr = &f, .len = 1 };                                 \
            uint32_t i2 = i1 ^ hash(uint8_t, slice_as_bytes(uint32_t, tmp), self->capacity); \
                                                                                             \
            if (self->slots[i1] == f) {                                                      \
                return optional_some(V, self->buckets[i1]);                                  \
            }                                                                                \
                                                                                             \
            if (self->slots[i2] == f) {                                                      \
                return optional_some(V, self->buckets[i2]);                                  \
            }                                                                                \
                                                                                             \
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
            if (self->slots[i1] == f) {                                                      \
                self->slots[i1] = 0;                                                         \
            }                                                                                \
                                                                                             \
            if (self->slots[i2] == f) {                                                      \
                self->slots[i2] = 0;                                                         \
            }                                                                                \
        }

    #define hashmap_impl_t(K, V)    \
        typedef struct {            \
            uint32_t* slots;        \
            V* buckets;             \
            size_t capacity;        \
        } CONCAT3(hashmap_, K, V);  \
        hashmap_impl_remove(K, V);  \
        hashmap_impl_get(K, V);     \
        hashmap_impl_get_ptr(K, V); \
        hashmap_impl_put(K, V);

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

    int main(void)
    {
        return 0;
    }

<!-- -->
