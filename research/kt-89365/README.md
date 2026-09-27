# KT-89365: resident memory that follows the thread count

[KT-89365](https://youtrack.jetbrains.com/issue/KT-89365) reports a Ktor service on Kotlin/Native whose
resident set is 7 MB + 2.96 MB x threads. JetBrains closed it as a duplicate of
[KT-74834](https://youtrack.jetbrains.com/issue/KT-74834) and pointed at
[KT-89435](https://youtrack.jetbrains.com/issue/KT-89435); both are open. Examined here on 2026-09-27;
**nothing from it is in the series.**

## The mechanism, reproduced

Every thread's `CustomAllocator` holds a current page per size class it allocates in
(`fixedBlockPages_`), until the next collection clears them (`CustomAllocator::PrepareForGC`). Every
page is its own `mmap` with `MAP_POPULATE` (`GCApi.cpp`), so it is resident in full however little of it
is used. `threads-rss/` isolates that: N threads each allocate one object in each of 22 size classes and
park, and resident memory is read before any collection runs (`2026-09-27-threads-rss.log`, two runs):

| | resident memory per thread |
|---|---|
| stock, 128 KiB pages (the compiler's default) | **2 827–2 832 KiB** |
| stock, `fixedBlockPageSize=16` | 326–356 KiB |
| stock runtime without `MAP_POPULATE`, 128 KiB | **44–89 KiB** |

2.83 MB a thread is the issue's 2.96 MB, from a program with nothing in it but the pattern: the pages a
thread holds, populated in full.

## The candidate patch, and why it is not in the series

`0004-lazy-allocator-pages.patch` drops `MAP_POPULATE`. In isolation it takes the per-thread cost from
2.8 MB to under 0.1 MB. On the synthetic Ktor service at a 128 MB live heap with 100 threads
(`2026-09-27-dial-yrt2-vs-yrt3.log`, 2.4.20-yrt.2 against the same plus 0004), resident memory fell by
about 5 % and CPU per request moved within the spread between rounds - because that service, like every
service built on sborka's conventions, already runs with 16 KiB pages, where a thread's pages are small.

So for this portfolio the workaround already carries the benefit, and after 2.4.20-yrt.1 the
remaining differences are noise (the owner's call, which stopped the measurement part-way). 0004 would
matter for a consumer on the default 128 KiB pages; for that consumer `fixedBlockPageSize=16` is the
no-patch answer, at the pause cost the page count used to carry - which 0001 and 0002 remove.
