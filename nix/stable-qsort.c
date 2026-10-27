/* qsort as glibc's stable merge sort, loaded into the compiler on every
 * build host. LLVM sorts with qsort, and where its comparisons tie, the C
 * library decides the order: glibc's merge sort keeps it, macOS's sort
 * does not, so the same compiler emitted differently ordered code on the
 * two systems. A stable sort has exactly one answer. */
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

typedef int (*compare_fn)(const void *, const void *);

static void merge_sort(char *base, char *scratch, size_t count, size_t size,
                       compare_fn compare) {
  if (count < 2) return;
  size_t half = count / 2;
  merge_sort(base, scratch, half, size, compare);
  merge_sort(base + half * size, scratch, count - half, size, compare);
  char *left = base, *left_end = base + half * size;
  char *right = left_end, *right_end = base + count * size;
  char *out = scratch;
  while (left < left_end && right < right_end) {
    /* The left element wins ties, which makes it stable. The halves and
     * the comparison are glibc's, so even a comparator that is not
     * consistent gets glibc's answer. */
    if (compare(left, right) <= 0) {
      memcpy(out, left, size);
      left += size;
    } else {
      memcpy(out, right, size);
      right += size;
    }
    out += size;
  }
  memcpy(out, left, (size_t)(left_end - left));
  out += left_end - left;
  memcpy(base, scratch, (size_t)(out - scratch));
}

static void stable_qsort(void *base, size_t count, size_t size,
                         compare_fn compare) {
  if (count < 2 || size == 0) return;
  char *scratch = malloc(count * size);
  /* Falling back to an unstable sort would bring the difference back. */
  if (scratch == NULL) abort();
  merge_sort(base, scratch, count, size, compare);
  free(scratch);
}

/* Only rustc itself: the tools it starts sort as they always have. The
 * build asks once that rustc confirms it loaded this; a loader that
 * refuses inserted libraries would otherwise fail silently. */
__attribute__((constructor)) static void confine(void) {
#ifdef __APPLE__
  unsetenv("DYLD_INSERT_LIBRARIES");
#else
  unsetenv("LD_PRELOAD");
#endif
  if (getenv("DNIX_STABLE_QSORT_CHECK") != NULL) {
    static const char loaded[] = "dnix-stable-qsort\n";
    write(2, loaded, sizeof loaded - 1);
  }
}

#ifdef __APPLE__
/* dyld replaces every image's qsort with this one when the library is
 * inserted with DYLD_INSERT_LIBRARIES. */
__attribute__((used, section("__DATA,__interpose"))) static const struct {
  const void *replacement;
  const void *replacee;
} interpose_qsort = {(const void *)stable_qsort, (const void *)qsort};
#else
/* Loaded with LD_PRELOAD, this definition comes before the C library's. */
void qsort(void *base, size_t count, size_t size, compare_fn compare) {
  stable_qsort(base, count, size, compare);
}
#endif
